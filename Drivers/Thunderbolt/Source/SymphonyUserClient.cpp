// SymphonyUserClient.cpp — IOUserClient implementation for app control commands.
// Receives ExternalMethod calls from the Maestro app and routes them to
// SymphonyThunderbridge::SendVendorCommand() over XLink.

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/OSData.h>

#include "SymphonyUserClient.h"
#include "SymphonyThunderbridge.h"
#include "SymphonyThunderbridgeShared.h"

#define UCLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "SymphonyTB-UC: " fmt, ##__VA_ARGS__)

// ── Instance Variables ──────────────────────────────────────────────────────

struct SymphonyUserClient_IVars {
    SymphonyThunderbridge *driver;
};

// ── Dispatch Table ──────────────────────────────────────────────────────────

static const IOUserClientMethodDispatch sMethods[kSelectorCount] = {
    [kSelectorSendVendor] = {
        .function                 = nullptr,  // handled inline in ExternalMethod
        .checkCompletionExists    = false,
        .checkScalarInputCount    = 0,
        .checkStructureInputSize  = sizeof(SymphonyVendorCommandInput),
        .checkScalarOutputCount   = 0,
        .checkStructureOutputSize = sizeof(SymphonyVendorCommandOutput),
    },
    [kSelectorReadMeters] = {
        .function                 = nullptr,  // handled inline in ExternalMethod
        .checkCompletionExists    = false,
        .checkScalarInputCount    = 0,
        .checkStructureInputSize  = 0,
        .checkScalarOutputCount   = 0,
        .checkStructureOutputSize = sizeof(SymphonyMeterOutput),
    },
    [kSelectorReadBoardTypes] = {
        .function                 = nullptr,  // handled inline in ExternalMethod
        .checkCompletionExists    = false,
        .checkScalarInputCount    = 0,
        .checkStructureInputSize  = 0,
        .checkScalarOutputCount   = 0,
        .checkStructureOutputSize = sizeof(SymphonyBoardTypesOutput),
    },
    [kSelectorReadTimingHealth] = {
        .function                 = nullptr,
        .checkCompletionExists    = false,
        .checkScalarInputCount    = 0,
        .checkStructureInputSize  = 0,
        .checkScalarOutputCount   = 0,
        .checkStructureOutputSize = sizeof(SymphonyTimingHealthOutput),
    },
    [kSelectorReadLinkState] = {
        .function                 = nullptr,
        .checkCompletionExists    = false,
        .checkScalarInputCount    = 0,
        .checkStructureInputSize  = 0,
        .checkScalarOutputCount   = 0,
        .checkStructureOutputSize = sizeof(SymphonyLinkStateOutput),
    },
    [kSelectorReadVendor] = {
        .function                 = nullptr,
        .checkCompletionExists    = false,
        .checkScalarInputCount    = 0,
        .checkStructureInputSize  = sizeof(SymphonyVendorReadInput),
        .checkScalarOutputCount   = 0,
        .checkStructureOutputSize = sizeof(SymphonyVendorReadOutput),
    },
};

// ── Lifecycle ───────────────────────────────────────────────────────────────

bool SymphonyUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(SymphonyUserClient_IVars, 1);
    if (!ivars) return false;
    UCLOG("init");
    return true;
}

void SymphonyUserClient::free()
{
    UCLOG("free");
    if (ivars) {
        OSSafeReleaseNULL(ivars->driver);
        IODelete(ivars, SymphonyUserClient_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

// ── SetDriver ───────────────────────────────────────────────────────────────

void SymphonyUserClient::SetDriver(SymphonyThunderbridge *driver)
{
    if (driver) driver->retain();
    if (ivars->driver) ivars->driver->release();
    ivars->driver = driver;
}

// ── ExternalMethod ──────────────────────────────────────────────────────────

kern_return_t SymphonyUserClient::ExternalMethod(
    uint64_t                              selector,
    IOUserClientMethodArguments          *arguments,
    const IOUserClientMethodDispatch     * /*dispatch*/,
    OSObject                             * /*target*/,
    void                                 * /*reference*/)
{
    if (selector >= kSelectorCount) {
        UCLOG("ExternalMethod: bad selector %llu", selector);
        return kIOReturnBadArgument;
    }

    // Validate against the dispatch table, then handle inline. With
    // function == nullptr, IOUserClient::ExternalMethod performs the scalar/struct
    // size checks in sMethods[selector] and, if they ALL PASS, returns
    // kIOReturnNoCompletion (NOT kIOReturnSuccess) "for the caller to implement the
    // method" (per the DriverKit SDK IOUserClient.iig comment). So we must treat
    // kIOReturnNoCompletion as "validation passed, handle inline" and only bail on a
    // genuinely different error (a real size-check failure). H2/#7: the previous
    // `ret != kIOReturnSuccess` test returned kIOReturnNoCompletion for EVERY valid
    // call, so the vendor path was dead — no command ever reached the handler below.
    kern_return_t ret = super::ExternalMethod(selector, arguments,
                                               &sMethods[selector], this, nullptr);
    if (ret != kIOReturnSuccess && ret != kIOReturnNoCompletion) {
        UCLOG("ExternalMethod: dispatch validation failed 0x%x", ret);
        return ret;
    }

    if (selector == kSelectorSendVendor) {
        // H2: Do NOT require arguments->structureOutput to be non-null here. In
        // DriverKit structureOutput is nil on ENTRY — the driver allocates it (see
        // below). The old check rejected every call with kIOReturnBadArgument.
        // Only the input struct must be present on entry.
        if (!arguments->structureInput) {
            UCLOG("ExternalMethod: missing struct input");
            return kIOReturnBadArgument;
        }

        auto inputData = arguments->structureInput;
        if (inputData->getLength() < sizeof(SymphonyVendorCommandInput)) {
            UCLOG("ExternalMethod: input too short (%zu)", inputData->getLength());
            return kIOReturnBadArgument;
        }

        auto *input = (const SymphonyVendorCommandInput *)inputData->getBytesNoCopy();
        if (!input || input->magic != kSymphonyUCMagic) {
            UCLOG("ExternalMethod: bad magic 0x%08x", input ? input->magic : 0);
            return kIOReturnBadArgument;
        }
        if (input->payloadLen > 64) {
            UCLOG("ExternalMethod: payload too large %u", input->payloadLen);
            return kIOReturnBadArgument;
        }
        if (!ivars->driver) {
            UCLOG("ExternalMethod: no driver");
            return kIOReturnNotReady;
        }

        kern_return_t cmdRet = ivars->driver->SendVendorCommand(
            input->command,
            input->value,
            input->payload,
            input->payloadLen);

        // Build output
        SymphonyVendorCommandOutput output;
        output.status = (cmdRet == kIOReturnSuccess) ? 0 : (uint32_t)cmdRet;

        auto outputData = OSData::withBytes(&output, sizeof(output));
        if (outputData) {
            arguments->structureOutput = outputData;
        }

        UCLOG("ExternalMethod: cmd=0x%02x value=0x%08x payload=%u → %s",
              input->command, input->value, input->payloadLen,
              cmdRet == kIOReturnSuccess ? "OK" : "FAIL");

        return kIOReturnSuccess;
    }

    if (selector == kSelectorReadMeters) {
        if (!ivars->driver) {
            UCLOG("ExternalMethod: no driver (meters)");
            return kIOReturnNotReady;
        }
        SymphonyMeterOutput output;
        output.status = 0;
        kern_return_t r = ivars->driver->ReadMeterBuffer(output.words);
        output.status = (r == kIOReturnSuccess) ? 0 : (uint32_t)r;

        auto outputData = OSData::withBytes(&output, sizeof(output));
        if (outputData) {
            arguments->structureOutput = outputData;
        }
        return kIOReturnSuccess;
    }

    if (selector == kSelectorReadBoardTypes) {
        if (!ivars->driver) {
            UCLOG("ExternalMethod: no driver (board types)");
            return kIOReturnNotReady;
        }
        SymphonyBoardTypesOutput output;
        output.board[0] = output.board[1] = 0;
        output.valid[0] = output.valid[1] = 0;
        kern_return_t r = ivars->driver->ReadBoardTypes(output.board, output.valid);
        output.status = (r == kIOReturnSuccess) ? 0 : (uint32_t)r;

        auto outputData = OSData::withBytes(&output, sizeof(output));
        if (outputData) {
            arguments->structureOutput = outputData;
        }
        UCLOG("ExternalMethod: board types = %u/%u (valid %u/%u)",
              output.board[0], output.board[1], output.valid[0], output.valid[1]);
        return kIOReturnSuccess;
    }

    if (selector == kSelectorReadTimingHealth) {
        if (!ivars->driver) {
            UCLOG("ExternalMethod: no driver (timing health)");
            return kIOReturnNotReady;
        }
        SymphonyTimingHealthOutput output = {};
        // ReadTimingHealth writes the complete packed 48-byte snapshot,
        // including the status word at offset zero. Passing &output.clkCtrl
        // shifted the snapshot by one word and overran this structure.
        kern_return_t r = ivars->driver->ReadTimingHealth(
            reinterpret_cast<uint32_t *>(&output));
        output.status = (r == kIOReturnSuccess) ? 0 : (uint32_t)r;
        auto outputData = OSData::withBytes(&output, sizeof(output));
        if (outputData) arguments->structureOutput = outputData;
        return kIOReturnSuccess;
    }

    if (selector == kSelectorReadLinkState) {
        if (!ivars->driver) {
            UCLOG("ExternalMethod: no driver (link state)");
            return kIOReturnNotReady;
        }
        SymphonyLinkStateOutput output = {};
        kern_return_t r = ivars->driver->ReadLinkState(reinterpret_cast<uint32_t *>(&output));
        output.status = (r == kIOReturnSuccess) ? 0 : (uint32_t)r;
        auto outputData = OSData::withBytes(&output, sizeof(output));
        if (outputData) arguments->structureOutput = outputData;
        return kIOReturnSuccess;
    }

    if (selector == kSelectorReadVendor) {
        if (!ivars->driver || !arguments->structureInput) return kIOReturnBadArgument;
        auto *input = (const SymphonyVendorReadInput *)arguments->structureInput->getBytesNoCopy();
        if (!input || input->magic != kSymphonyUCMagic || input->responseLen > 64)
            return kIOReturnBadArgument;
        SymphonyVendorReadOutput output = {};
        output.responseLen = input->responseLen;
        kern_return_t r = ivars->driver->ReadVendorCommand(
            input->command, input->value, output.payload, input->responseLen);
        output.status = (r == kIOReturnSuccess) ? 0 : (uint32_t)r;
        auto outputData = OSData::withBytes(&output, sizeof(output));
        if (outputData) arguments->structureOutput = outputData;
        return kIOReturnSuccess;
    }

    return kIOReturnUnsupported;
}
