/// DaemonClient.cpp — C++ MaestroLink IPC client for Apogee daemon
///
/// Ported from Apps/Maestro/MaestroDevice/CoreAudioDeviceConnection.swift (DaemonSocket).
/// Frame: [MLNK magic (4)][packet size (4)][packed message (N)]
/// Message: [Transportable (12)][MessageContent (16)][type-specific payload]
///
/// Evidence: og_source/maestrolink/Software/Messaging/MaestroLinkMessaging.h
/// Evidence: Drivers/USB/Plugin/Software/daemonCommunication.cpp

#include "DaemonClient.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <cstring>
#include <os/log.h>

static os_log_t sClientLog = os_log_create("com.apogee.audio.symphonyio-asp", "daemon-client");

DaemonClient::DaemonClient() = default;

DaemonClient::~DaemonClient() {
    disconnect();
}

bool DaemonClient::connect() {
    std::lock_guard<std::mutex> lock(mMutex);

    if (mConnected) return true;

    // Ignore SIGPIPE so broken pipe doesn't kill coreaudiod
    signal(SIGPIPE, SIG_IGN);

    // Create UNIX domain socket
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        os_log_error(sClientLog, "Cannot create UNIX socket: errno %d", errno);
        return false;
    }

    // Connect to daemon
    struct sockaddr_un addr = {};
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, kSocketPath, sizeof(addr.sun_path));

    if (::connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        os_log_error(sClientLog, "Cannot connect to daemon socket: %{public}s",
                     strerror(errno));
        close(fd);
        return false;
    }

    mSocketFD = fd;
    os_log_info(sClientLog, "Connected to daemon socket at %{public}s", kSocketPath);

    // Send registration
    // Payload: Transportable(12) + MessageContent(16) + RegistrationContent(12) + strings
    auto uidBytes = mDeviceUID + '\0';
    auto bundleBytes = mBundleID + '\0';
    size_t regPayloadSize = 12 + 16 + 12 + uidBytes.size() + bundleBytes.size();

    std::vector<uint8_t> payload(regPayloadSize, 0);
    mMessageCounter++;
    size_t offset = 0;

    // Transportable (12 bytes)
    writeTransportable(payload.data(), offset,
                      static_cast<uint32_t>(regPayloadSize),
                      kObjectType_Registration);

    // MessageContent (16 bytes)
    writeMessageContent(payload.data(), offset,
                       mMessageCounter, kPriority_Register, kMsgType_Registration);

    // RegistrationContent (12 bytes): audioDeviceID, uidLen, bundleLen
    uint32_t devID = 0;  // Daemon assigns device ID from registration
    uint32_t uidLen = static_cast<uint32_t>(uidBytes.size());
    uint32_t bundleLen = static_cast<uint32_t>(bundleBytes.size());
    memcpy(payload.data() + offset, &devID, 4); offset += 4;
    memcpy(payload.data() + offset, &uidLen, 4); offset += 4;
    memcpy(payload.data() + offset, &bundleLen, 4); offset += 4;

    // Strings (null-terminated)
    memcpy(payload.data() + offset, uidBytes.data(), uidBytes.size());
    offset += uidBytes.size();
    memcpy(payload.data() + offset, bundleBytes.data(), bundleBytes.size());

    auto frame = buildFrame(payload);
    if (!sendFrame(frame)) {
        os_log_error(sClientLog, "Failed to send registration");
        close(fd);
        mSocketFD = -1;
        return false;
    }

    // Read registration response
    auto response = readSingleMessage(2000);
    if (response.empty()) {
        os_log_error(sClientLog, "No registration response from daemon");
        close(fd);
        mSocketFD = -1;
        return false;
    }

    // Parse response: frame(8) + Transportable(12) + MessageContent(16) + ResponseContents(12)
    size_t minSize = 8 + 12 + 16 + 12;
    if (response.size() < minSize) {
        os_log_error(sClientLog, "Registration response too short (%zu bytes)",
                     response.size());
        close(fd);
        mSocketFD = -1;
        return false;
    }

    // Check return status (first 4 bytes of ResponseContents)
    uint32_t returnStatus = 0;
    memcpy(&returnStatus, response.data() + 8 + 12 + 16, 4);
    if (returnStatus != 0) {
        os_log_error(sClientLog, "Registration rejected: status %u", returnStatus);
        close(fd);
        mSocketFD = -1;
        return false;
    }

    // Extract DeviceControllerID from response data (Bug 3 fix)
    // ResponseContents: [returnStatus(4)][senderPID(4)][returnDataSize(4)]
    // Data follows immediately after ResponseContents
    uint32_t returnDataSize = 0;
    memcpy(&returnDataSize, response.data() + 8 + 12 + 16 + 8, 4);
    if (returnDataSize >= 4 && response.size() >= minSize + 4) {
        memcpy(&mDeviceControllerID, response.data() + minSize, 4);
        os_log_info(sClientLog, "Registration OK, DeviceControllerID: %u",
                    mDeviceControllerID);
    } else {
        os_log_info(sClientLog, "Registration OK (no DeviceControllerID in response)");
    }

    mConnected = true;
    return true;
}

void DaemonClient::disconnect() {
    std::lock_guard<std::mutex> lock(mMutex);
    if (mSocketFD >= 0) {
        close(mSocketFD);
        mSocketFD = -1;
    }
    mConnected = false;
}

bool DaemonClient::isConnected() const {
    std::lock_guard<std::mutex> lock(mMutex);
    return mConnected;
}

bool DaemonClient::getProperty(uint32_t propertyID, uint32_t channel, bool isInput,
                                void* outData, uint32_t* outSize) {
    std::lock_guard<std::mutex> lock(mMutex);

    if (!mConnected || mSocketFD < 0) return false;

    // Payload: Transportable(12) + MessageContent(16) + GetPropertyContents(28)
    size_t payloadSize = 12 + 16 + 28;
    std::vector<uint8_t> payload(payloadSize, 0);
    mMessageCounter++;
    size_t offset = 0;

    writeTransportable(payload.data(), offset,
                      static_cast<uint32_t>(payloadSize), kObjectType_GetProperty);
    writeMessageContent(payload.data(), offset,
                       mMessageCounter, kPriority_Get, kMsgType_GetProperty);

    // GetPropertyContents (28 bytes)
    uint32_t devCtrl = mDeviceControllerID;
    uint32_t nonCA = 0;
    uint32_t maxReturn = kMaxPacketSize;
    uint32_t inputSize = 0;
    uint8_t isIn = isInput ? 1 : 0;

    memcpy(payload.data() + offset, &devCtrl, 4); offset += 4;
    memcpy(payload.data() + offset, &nonCA, 4); offset += 4;
    memcpy(payload.data() + offset, &propertyID, 4); offset += 4;
    memcpy(payload.data() + offset, &channel, 4); offset += 4;
    memcpy(payload.data() + offset, &maxReturn, 4); offset += 4;
    memcpy(payload.data() + offset, &inputSize, 4); offset += 4;
    memcpy(payload.data() + offset, &isIn, 1); offset += 1;

    auto frame = buildFrame(payload);
    if (!sendFrame(frame)) return false;

    auto response = readResponseSkippingNotifications(2000);
    if (response.empty()) return false;

    uint32_t status = 0;
    std::vector<uint8_t> data;
    if (!parseResponse(response, status, data)) return false;
    if (status != 0) return false;

    if (outData && outSize) {
        uint32_t copySize = std::min(*outSize, static_cast<uint32_t>(data.size()));
        memcpy(outData, data.data(), copySize);
        *outSize = copySize;
    }

    return true;
}

bool DaemonClient::setProperty(uint32_t propertyID, uint32_t channel, bool isInput,
                                const void* data, uint32_t dataSize) {
    std::lock_guard<std::mutex> lock(mMutex);

    if (!mConnected || mSocketFD < 0) return false;

    // Payload: Transportable(12) + MessageContent(16) + SetPropertyContents(28) + data
    size_t fixedSize = 12 + 16 + 28;
    size_t payloadSize = fixedSize + dataSize;
    std::vector<uint8_t> payload(payloadSize, 0);
    mMessageCounter++;
    size_t offset = 0;

    writeTransportable(payload.data(), offset,
                      static_cast<uint32_t>(payloadSize), kObjectType_SetProperty);
    writeMessageContent(payload.data(), offset,
                       mMessageCounter, kPriority_Set, kMsgType_SetProperty);

    // SetPropertyContents (28 bytes)
    // Field order: devCtrl, nonCA, propID, channel, m_dataSize(aux), m_inputSize(value), isInput
    uint32_t devCtrl = mDeviceControllerID;
    uint32_t nonCA = 0;
    uint32_t auxDataSize = 0;       // m_dataSize: auxiliary (unused)
    uint32_t inputSizeField = dataSize;  // m_inputSize: value size (PRIMARY)
    uint8_t isIn = isInput ? 1 : 0;

    memcpy(payload.data() + offset, &devCtrl, 4); offset += 4;
    memcpy(payload.data() + offset, &nonCA, 4); offset += 4;
    memcpy(payload.data() + offset, &propertyID, 4); offset += 4;
    memcpy(payload.data() + offset, &channel, 4); offset += 4;
    memcpy(payload.data() + offset, &auxDataSize, 4); offset += 4;
    memcpy(payload.data() + offset, &inputSizeField, 4); offset += 4;
    memcpy(payload.data() + offset, &isIn, 1); offset += 1;
    offset += 3;  // padding to 28

    // Data payload
    if (data && dataSize > 0) {
        memcpy(payload.data() + offset, data, dataSize);
    }

    auto frame = buildFrame(payload);
    if (!sendFrame(frame)) return false;

    // Read response, skipping PropertyChanged notifications
    auto response = readResponseSkippingNotifications(2000);
    if (response.empty()) {
        os_log_error(sClientLog, "No SetProperty response for 0x%08X", propertyID);
        return false;
    }

    uint32_t status = 0;
    std::vector<uint8_t> respData;
    if (!parseResponse(response, status, respData)) return false;

    if (status != 0) {
        os_log_error(sClientLog, "SetProperty 0x%08X failed: status %u",
                     propertyID, status);
        return false;
    }

    return true;
}

// MARK: - Frame Building

std::vector<uint8_t> DaemonClient::buildFrame(const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> frame(8 + payload.size());
    uint32_t magic = kMagic;
    uint32_t packetSize = static_cast<uint32_t>(payload.size());
    memcpy(frame.data(), &magic, 4);
    memcpy(frame.data() + 4, &packetSize, 4);
    memcpy(frame.data() + 8, payload.data(), payload.size());
    return frame;
}

void DaemonClient::writeTransportable(uint8_t* buf, size_t& offset,
                                       uint32_t totalPacked, uint32_t objectType) {
    memcpy(buf + offset, &totalPacked, 4); offset += 4;
    memcpy(buf + offset, &objectType, 4); offset += 4;
    uint8_t byteOrder = 0x4C;  // 'L' for Little Endian
    memcpy(buf + offset, &byteOrder, 1); offset += 1;
    offset += 3;  // padding
}

void DaemonClient::writeMessageContent(uint8_t* buf, size_t& offset,
                                         uint32_t msgID, int32_t priority,
                                         uint8_t msgType) {
    memcpy(buf + offset, &msgID, 4); offset += 4;
    memcpy(buf + offset, &priority, 4); offset += 4;
    uint32_t pid = static_cast<uint32_t>(getpid());
    memcpy(buf + offset, &pid, 4); offset += 4;
    memcpy(buf + offset, &msgType, 1); offset += 1;
    offset += 3;  // padding
}

// MARK: - Socket I/O

bool DaemonClient::sendFrame(const std::vector<uint8_t>& frame) {
    size_t totalSent = 0;
    while (totalSent < frame.size()) {
        ssize_t sent = ::send(mSocketFD,
                              frame.data() + totalSent,
                              frame.size() - totalSent, 0);
        if (sent <= 0) {
            os_log_error(sClientLog, "Socket send failed: %{public}s", strerror(errno));
            mConnected = false;
            return false;
        }
        totalSent += static_cast<size_t>(sent);
    }
    return true;
}

std::vector<uint8_t> DaemonClient::readSingleMessage(int timeoutMs) {
    struct pollfd pfd = { mSocketFD, POLLIN, 0 };
    if (poll(&pfd, 1, timeoutMs) <= 0) return {};

    // Read frame header (8 bytes: magic + size)
    uint8_t header[8] = {};
    ssize_t headerRead = recv(mSocketFD, header, 8, MSG_WAITALL);
    if (headerRead != 8) return {};

    uint32_t packetSize = 0;
    memcpy(&packetSize, header + 4, 4);
    if (packetSize == 0 || packetSize > 65536) return {};

    // Read payload
    std::vector<uint8_t> payload(packetSize);
    size_t totalRead = 0;
    while (totalRead < packetSize) {
        ssize_t n = recv(mSocketFD,
                         payload.data() + totalRead,
                         packetSize - totalRead, 0);
        if (n <= 0) break;
        totalRead += static_cast<size_t>(n);
    }
    if (totalRead != packetSize) return {};

    // Combine header + payload
    std::vector<uint8_t> result(8 + packetSize);
    memcpy(result.data(), header, 8);
    memcpy(result.data() + 8, payload.data(), packetSize);
    return result;
}

std::vector<uint8_t> DaemonClient::readResponseSkippingNotifications(int timeoutMs) {
    // Skip PropertyChanged notifications (objectType=6) until we get Response (objectType=2).
    // objectType is at offset 8+4 (frame header + first Transportable field)
    for (int attempt = 0; attempt < 10; attempt++) {
        auto message = readSingleMessage(timeoutMs);
        if (message.empty()) return {};
        if (message.size() < 16) return message;

        uint32_t objectType = 0;
        memcpy(&objectType, message.data() + 8 + 4, 4);

        if (objectType == kObjectType_Response) {
            return message;
        }
        // Skip notifications and try again
        os_log_debug(sClientLog, "Skipping notification objectType=%u", objectType);
    }
    os_log_error(sClientLog, "Too many notifications without a response");
    return {};
}

bool DaemonClient::parseResponse(const std::vector<uint8_t>& response,
                                  uint32_t& status,
                                  std::vector<uint8_t>& data) {
    // frame(8) + Transportable(12) + MessageContent(16) + ResponseContents(12)
    size_t minSize = 8 + 12 + 16 + 12;
    if (response.size() < minSize) return false;

    // ResponseContents: [returnStatus(4)][senderPID(4)][returnDataSize(4)]
    memcpy(&status, response.data() + 8 + 12 + 16, 4);

    uint32_t returnDataSize = 0;
    memcpy(&returnDataSize, response.data() + 8 + 12 + 16 + 8, 4);

    size_t dataOffset = minSize;
    if (returnDataSize > 0 && dataOffset + returnDataSize <= response.size()) {
        data.assign(response.begin() + dataOffset,
                    response.begin() + dataOffset + returnDataSize);
    }

    return true;
}
