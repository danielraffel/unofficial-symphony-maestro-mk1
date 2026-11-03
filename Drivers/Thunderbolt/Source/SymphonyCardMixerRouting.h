// Pure card-mixer routing calculations shared by the ThunderBridge driver and
// its host-side invariant test.
#pragma once

#include <stdint.h>

static constexpr uint8_t kThunderboltMixerSoftwareReturnCommand = 0xB4;
static constexpr uint32_t kThunderboltCardMixerRoutingRegister = 0x2200;
static constexpr uint32_t kThunderboltCardMixerHostPlaybackBase = 64;

static constexpr bool IsThunderboltSoftwareReturnSource(uint8_t source)
{
    return source <= 7;
}

// The original PCIe mixer selected a stereo host-playback pair by advancing
// PCI_OUT0 by two TDM slots per source ID.
static constexpr uint32_t ThunderboltSoftwareReturnSlot(uint8_t source, uint8_t side)
{
    return kThunderboltCardMixerHostPlaybackBase + static_cast<uint32_t>(source) * 2 + side;
}

// Mixer IDs exposed by Maestro are 1-based. Each stereo mixer occupies two
// consecutive mono return routes in the card FPGA.
static constexpr uint32_t ThunderboltMixerReturnRegister(uint16_t mixerID, uint8_t side)
{
    return kThunderboltCardMixerRoutingRegister +
           ((static_cast<uint32_t>(mixerID - 1) * 2) + side) * 4;
}

// Each logical stereo mixer occupies two consecutive physical coefficient
// banks: Mixer 1 -> 0/1, Mixer 2 -> 2/3.
static constexpr uint32_t ThunderboltMixerPhysicalBase(uint16_t mixerID)
{
    return static_cast<uint32_t>(mixerID - 1) * 2;
}

// ── Card output routing (host playback → XLink TX channel) ────────────────
//
// The original PCIe routing controller never wrote a host-playback source into
// the Symphony's own routing table. It routed on the card: the XLink TX
// channel feeding Symphony output k selects a TDM slot — PCI_OUT n for DAW
// playback n, MIXER0_OUT+2m+side for a mixer bus — through
// SM_REG_OUTPUT_ROUTING (0x2100), and a route is "cleared" by dropping the
// enable bit (SymphonyPCIeRoutingController.cpp:964-1216 routeSymphonyHW →
// Symphony64Card CMD_ROUTE_OUTPUTS → Sym64Routing::SetOutputSource,
// Sym64RoutingRegisters.h:94/159/226). This command exposes that register to
// Maestro. Payload: [xlinkChannel 0..31, tdmSlot 0..255, enable 0/1].
static constexpr uint8_t  kThunderboltCardOutputRouteCommand   = 0xB5;
static constexpr uint32_t kThunderboltCardOutputRoutingRegister = 0x2100;
static constexpr uint32_t kThunderboltCardOutputChannels        = 32;
static constexpr uint32_t kThunderboltCardRouteEnable           = 0x100;

static constexpr uint32_t ThunderboltCardOutputRouteRegister(uint8_t channel)
{
    return kThunderboltCardOutputRoutingRegister + static_cast<uint32_t>(channel) * 4;
}

static constexpr uint32_t ThunderboltCardOutputRouteWord(uint8_t tdmSlot, bool enabled)
{
    return static_cast<uint32_t>(tdmSlot) | (enabled ? kThunderboltCardRouteEnable : 0u);
}
