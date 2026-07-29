#!/bin/bash
CYCLES=5
PASS=0
FAIL=0

# Setup - ensure scripts exist
SCRIPT_DIR=/tmp/harbor-pkg
# DO NOT delete this dir during cleanup!

for i in $(seq 1 $CYCLES); do
    echo "============================================"
    echo "  CYCLE $i / $CYCLES"
    echo "============================================"

    echo "[CLEAN]"
    cd /opt/harbor 2>/dev/null && docker compose down -v 2>/dev/null; true
    for c in $(docker ps -aq); do docker rm -f $c 2>/dev/null; done
    docker rmi -f $(docker images -q goharbor) 2>/dev/null; true
    docker rmi -f golang:1.26.4 node:22.22.3 2>/dev/null; true
    docker image prune -a -f 2>/dev/null; true
    docker builder prune -a -f 2>/dev/null; true
    # CAREFUL: do NOT delete $SCRIPT_DIR
    rm -rf /opt/harbor /opt/build/harbor /data/harbor /data/registry /data/secret /var/log/harbor /usr/local/go \
           /tmp/harbor_extract /tmp/harbor_cfg /tmp/harbor-base-build /tmp/harbor-photon-build \
           /tmp/Dockerfile.* /tmp/htpasswd.py /tmp/go*.tar.gz /tmp/node-*.tar.xz /tmp/dpkg_*.tar.xz \
           /tmp/spectral-linux-x64 /tmp/build-cache
    docker pull quay.io/centos/centos:stream9 2>/dev/null || true
    docker tag quay.io/centos/centos:stream9 centos:stream9 2>/dev/null || true

    echo "[STEP1] build_base"
    if ! bash $SCRIPT_DIR/build_base.sh; then
        echo "CYCLE $i FAIL at build_base"
        FAIL=$((FAIL+1))
        continue
    fi

    echo "[STEP2] build_local"
    if ! bash $SCRIPT_DIR/build_local.sh 2.11.0 harbor.testops.local/testops; then
        echo "CYCLE $i FAIL at build_local"
        FAIL=$((FAIL+1))
        continue
    fi

    echo "[STEP3] install"
    if ! bash $SCRIPT_DIR/install_harbor.sh 2.11.0 192.168.0.102 Harbor12345 harbor.testops.local/testops; then
        echo "CYCLE $i FAIL at install"
        FAIL=$((FAIL+1))
        continue
    fi

    sleep 20
    if curl -sk https://127.0.0.1 2>/dev/null | grep -q Harbor; then
        echo "CYCLE $i PASS"
        PASS=$((PASS+1))
    else
        echo "CYCLE $i FAIL at verify"
        FAIL=$((FAIL+1))
    fi
done
echo "============================================"
echo "  RESULT: $PASS / $CYCLES PASS, $FAIL FAIL"
echo "============================================"
