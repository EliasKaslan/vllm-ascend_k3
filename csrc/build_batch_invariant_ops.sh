#!/bin/bash

set -euo pipefail

# arguments:
# $1: SOC_ARG (ascend910b, ascend910_93, ascend950)

SOC_ARG="${1:-}"

log() {
    echo "[install_batch_invariant] $*"
}

# This script is only invoked when VLLM_BATCH_INVARIANT=1 (see csrc/build_aclnn.sh),
# i.e. the user explicitly asked for batch-invariant ops. Any failure below must
# therefore abort the build with a non-zero exit code. Previously every failure
# path only logged a message and the script still exited 0, so `pip install -e .`
# reported "Successfully installed" while batch_invariant_ops was actually missing
# -- a silent, hard-to-diagnose broken install.
fail() {
    log "ERROR: $*"
    log "ERROR: batch_invariant_ops was NOT installed, but VLLM_BATCH_INVARIANT=1 was requested."
    log "ERROR: aborting so the build fails loudly instead of producing a non-batch-invariant install."
    exit 1
}

# validate arguments
if [[ -z "${SOC_ARG}" ]]; then
    fail "SOC_ARG is required as first argument"
fi

log "Starting batch_invariant installation..."
log "SOC_ARG=${SOC_ARG}"

# determine device type from SOC_ARG
case "${SOC_ARG}" in
    ascend910b)
        BATCH_INVARIANT_DEVICE="910b"
        ;;
    ascend910_93)
        BATCH_INVARIANT_DEVICE="A3"
        ;;
    ascend950*)
        BATCH_INVARIANT_DEVICE="950"
        ;;
    *)
        log "Warning: batch_invariant not available for SOC_ARG=${SOC_ARG}; skipping"
        exit 0
        ;;
esac

# detect system architecture
ARCH_INFO=$(uname -m)
case "${ARCH_INFO}" in
    aarch64)
        ARCH_SUFFIX="aarch64"
        ;;
    x86_64)
        ARCH_SUFFIX="x86_64"
        ;;
    *)
        log "Warning: unknown architecture ${ARCH_INFO}; cannot determine batch_invariant package"
        exit 0
        ;;
esac

# download and install run package
BATCH_INVARIANT_RUN_URL="https://vllm-ascend.obs.cn-north-4.myhuaweicloud.com/vllm-ascend/cann-ops-batch_invariant-${BATCH_INVARIANT_DEVICE}-2.0.0-linux.${ARCH_SUFFIX}.run"
BATCH_INVARIANT_RUN_FILE="cann-ops-batch_invariant-${BATCH_INVARIANT_DEVICE}-2.0.0-linux.${ARCH_SUFFIX}.run"

log "Downloading batch_invariant run package..."
unset ASCEND_CUSTOM_OPP_PATH
# --max-time 5 was routinely exceeded under compile load; use a longer timeout with
# retries (matching the run package) and do not swallow curl's stderr.
if curl --max-time 120 --retry 3 --retry-delay 2 -sS -k -O "${BATCH_INVARIANT_RUN_URL}" && [[ -f "${BATCH_INVARIANT_RUN_FILE}" ]]; then
    chmod +x "${BATCH_INVARIANT_RUN_FILE}"
    log "Running installer: ${BATCH_INVARIANT_RUN_FILE}"
    if "./${BATCH_INVARIANT_RUN_FILE}"; then
        log "batch_invariant run package installed successfully"
    else
        rm -f "${BATCH_INVARIANT_RUN_FILE}"
        fail "Failed to install batch_invariant run package"
    fi
else
    rm -f "${BATCH_INVARIANT_RUN_FILE}"
    fail "Failed to download batch_invariant run package: ${BATCH_INVARIANT_RUN_URL}"
fi
# clean up downloaded run file (always clean, regardless of success/failure)
rm -f "${BATCH_INVARIANT_RUN_FILE}"

# download and install whl package
BATCH_INVARIANT_WHL_URL="https://vllm-ascend.obs.cn-north-4.myhuaweicloud.com/vllm-ascend/batch_invariant-torch_ops_extension-2.0.0.zip"
BATCH_INVARIANT_WHL_FILE="batch_invariant-torch_ops_extension-2.0.0.zip"

log "Downloading batch_invariant whl package..."
if curl --max-time 120 --retry 3 --retry-delay 2 -sS -k -O "${BATCH_INVARIANT_WHL_URL}" && [[ -f "${BATCH_INVARIANT_WHL_FILE}" ]]; then
    if python -m zipfile -e "${BATCH_INVARIANT_WHL_FILE}" .; then
        if [[ -d "torch_ops_extension/batch_invariant_ops" ]]; then
            cd torch_ops_extension/batch_invariant_ops
            log "Building and installing batch_invariant whl package..."
            if bash build_and_install.sh; then
                log "batch_invariant whl package installed successfully"
            else
                cd - >/dev/null
                rm -rf "${BATCH_INVARIANT_WHL_FILE}" torch_ops_extension
                fail "Failed to build and install batch_invariant whl package"
            fi
            cd - >/dev/null
        else
            rm -rf "${BATCH_INVARIANT_WHL_FILE}" torch_ops_extension
            fail "batch_invariant_ops directory not found in zip"
        fi
    else
        rm -rf "${BATCH_INVARIANT_WHL_FILE}" torch_ops_extension
        fail "Failed to unzip batch_invariant whl package"
    fi
else
    rm -rf "${BATCH_INVARIANT_WHL_FILE}" torch_ops_extension
    fail "Failed to download batch_invariant whl package: ${BATCH_INVARIANT_WHL_URL}"
fi
# clean up downloaded files (always clean, regardless of success/failure)
rm -rf "${BATCH_INVARIANT_WHL_FILE}" torch_ops_extension

# Verify the extension module is actually importable. pip hides build output unless
# run with -v, so without this check a broken install still looks successful.
log "Verifying batch_invariant_ops is importable..."
if ! python -c "import batch_invariant_ops"; then
    fail "Post-install verification failed: 'import batch_invariant_ops' did not succeed"
fi
log "Post-install verification OK: import batch_invariant_ops succeeded"

log "batch_invariant_ops build completed"
