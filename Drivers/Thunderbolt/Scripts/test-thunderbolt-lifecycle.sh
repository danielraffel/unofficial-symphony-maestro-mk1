#!/bin/bash
set -euo pipefail

SOURCE="$(cd "$(dirname "$0")/../Source" && pwd)/SymphonyThunderbridge.cpp"
test -f "$SOURCE"

python3 - "$SOURCE" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
start = source.index("kern_return_t IMPL(SymphonyThunderbridge, Stop)")
end = source.index("// ── NewUserClient", start)
block = source[start:end]

stopping = block.index('__atomic_store_n(&ivars->stopping, true')
io_running = block.index('__atomic_store_n(&ivars->ioRunning, false')
tx_shutdown = block.index('__atomic_store_n(&ivars->txShutdown, true')
mute = block.index('kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute')
assert stopping < mute
assert io_running < mute
assert tx_shutdown < mute

cancel = block.index('ivars->interruptSource->Cancel(^')
drain = block.index('iv->xlinkQueue->DispatchSync(^{});', cancel)
complete_dma = block.index('CompleteDMA(kIODMACommandCompleteDMANoOptions)', drain)
meter_disable = block.index('iv->meterDMAActive = false', drain)
assert drain < complete_dma
assert drain < meter_disable

print('ThunderBridge lifecycle teardown ordering: PASS')
PY
