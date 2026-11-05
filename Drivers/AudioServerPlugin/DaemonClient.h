/// DaemonClient.h — C++ MaestroLink IPC client for Apogee daemon
///
/// Ported from Apps/Maestro/MaestroDevice/CoreAudioDeviceConnection.swift (DaemonSocket).
/// Implements the MaestroLink framing protocol over UNIX domain socket.
///
/// IPC strategy: UNIX socket as primary path (proven to work from coreaudiod
/// via legacy HAL plugin). Mach/XPC available as alternative if sandbox blocks
/// socket access — swapping transport is a one-file change (this file).
///
/// Evidence: og_source/maestrolink/Software/Messaging/MaestroLinkMessaging.h
/// Evidence: og_source/maestrolink/Software/Daemons/daemonCommunication.cpp

#pragma once

#include <cstdint>
#include <string>
#include <vector>
#include <mutex>

class DaemonClient {
public:
    DaemonClient();
    ~DaemonClient();

    // Non-copyable
    DaemonClient(const DaemonClient&) = delete;
    DaemonClient& operator=(const DaemonClient&) = delete;

    /// Connect to daemon socket and send registration.
    /// Returns true on success.
    bool connect();

    /// Disconnect from daemon.
    void disconnect();

    /// Whether we have an active connection.
    bool isConnected() const;

    /// Send GetProperty and return response data.
    /// propertyID: FourCC selector (e.g., 0x41456C33 = 'AEl3' = outputLevel)
    /// channel: channel index (0 for global properties)
    /// isInput: true for input scope, false for output
    /// outData/outSize: receives response data
    /// Returns true on success.
    bool getProperty(uint32_t propertyID, uint32_t channel, bool isInput,
                     void* outData, uint32_t* outSize);

    /// Send SetProperty.
    /// data/dataSize: property value to set
    /// Returns true on success.
    bool setProperty(uint32_t propertyID, uint32_t channel, bool isInput,
                     const void* data, uint32_t dataSize);

private:
    static constexpr const char* kSocketPath =
        "/var/run/com.apogee.symphonyIOUSBDaemon/Socket";
    static constexpr uint32_t kMagic = 0x4D4C4E4B;  // 'MLNK'
    static constexpr uint32_t kMaxPacketSize = 4096;

    // Object types in Transportable header
    static constexpr uint32_t kObjectType_Response = 2;
    static constexpr uint32_t kObjectType_Registration = 3;
    static constexpr uint32_t kObjectType_GetProperty = 4;
    static constexpr uint32_t kObjectType_SetProperty = 5;
    static constexpr uint32_t kObjectType_PropertyChanged = 6;

    // Message types
    static constexpr uint8_t kMsgType_Registration = 0x01;
    static constexpr uint8_t kMsgType_SetProperty = 0x03;
    static constexpr uint8_t kMsgType_GetProperty = 0x05;

    // Priority levels
    static constexpr int32_t kPriority_Set = 2;
    static constexpr int32_t kPriority_Get = 3;
    static constexpr int32_t kPriority_Register = 4;

    int mSocketFD = -1;
    bool mConnected = false;
    uint32_t mMessageCounter = 0;
    uint32_t mDeviceControllerID = 0;
    mutable std::mutex mMutex;

    // Device UID for registration
    std::string mDeviceUID =
        "AppleUSBAudioEngine:Apogee:Symphony I/O : USB Audio:2100000:1,2";
    std::string mBundleID = "com.apogee.audio.symphonyio-asp";

    // Frame building
    std::vector<uint8_t> buildFrame(const std::vector<uint8_t>& payload);
    void writeTransportable(uint8_t* buf, size_t& offset,
                           uint32_t totalPacked, uint32_t objectType);
    void writeMessageContent(uint8_t* buf, size_t& offset,
                            uint32_t msgID, int32_t priority, uint8_t msgType);

    // Socket I/O
    bool sendFrame(const std::vector<uint8_t>& frame);
    std::vector<uint8_t> readSingleMessage(int timeoutMs);
    std::vector<uint8_t> readResponseSkippingNotifications(int timeoutMs);
    bool parseResponse(const std::vector<uint8_t>& response,
                      uint32_t& status, std::vector<uint8_t>& data);
};
