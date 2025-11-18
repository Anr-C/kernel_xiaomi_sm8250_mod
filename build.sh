#!/bin/bash

# Some logics of this script are copied from [scripts/build_kernel]. Thanks to UtsavBalar1231.

# Ensure the script exits on error
set -e

TOOLCHAIN_PATH=$HOME/proton-clang/proton-clang-20210522/bin
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE=$1
KERNEL_SOURCE="$(pwd)"

if [ -z "$1" ]; then
    echo "Error: No argument provided, please specific a target device." 
    echo "If you need KernelSU, please add [ksu] as the second arg."
    echo "Examples:"
    echo "Build for lmi(K30 Pro/POCO F2 Pro) without KernelSU:"
    echo "    bash build.sh lmi"
    echo "Build for umi(Mi10) with KernelSU:"
    echo "    bash build.sh umi ksu"
    exit 1
fi


if [ ! -d $TOOLCHAIN_PATH ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    echo "Please ensure the toolchain is there, or change TOOLCHAIN_PATH in the script to your toolchain path."
    exit 1
fi

echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"

if ! command -v aarch64-linux-gnu-ld >/dev/null 2>&1; then
    echo "[aarch64-linux-gnu-ld] does not exist, please check your environment."
    exit 1
fi

if ! command -v arm-linux-gnueabi-ld >/dev/null 2>&1; then
    echo "[arm-linux-gnueabi-ld] does not exist, please check your environment."
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "[clang] does not exist, please check your environment."
    exit 1
fi


# Enable ccache for speed up compiling 
export CCACHE_DIR="$HOME/.cache/ccache_mikernel" 
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:$PATH"
echo "CCACHE_DIR: [$CCACHE_DIR]"


MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"


# if [ "$1" == "j1" ]; then
#     make $MAKE_ARGS -j1
#     exit
# fi

# if [ "$1" == "continue" ]; then
#     make $MAKE_ARGS -j$(nproc)
#     exit
# fi

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    echo "Avaliable defconfigs, please choose one target from below down:"
    ls arch/arm64/configs/*_defconfig
    exit 1
fi


# Check clang is existing.
echo "[clang --version]:"
clang --version

echo "[clean -- Code]:"
git reset --hard HEAD && git clean -fd

KSU_ZIP_STR=NoKernelSU
if [ "$2" == "ksu" ]; then
    KSU_ENABLE=1
    KSU_ZIP_STR=SukiSU-SUSFS
else
    KSU_ENABLE=0
fi

if [ "$2" = "aosp" ] || [ "$3" = "aosp" ]; then
    BUILD_AOSP=1
else
    BUILD_AOSP=0
fi

echo "TARGET_DEVICE: $TARGET_DEVICE"

if [ $KSU_ENABLE -eq 1 ]; then

    echo "Configuring KernelSU (配置 KernelSU)"
    DRIVER_DIR="$KERNEL_SOURCE/drivers"
    DRIVER_MAKEFILE=$DRIVER_DIR/Makefile
    DRIVER_KCONFIG=$DRIVER_DIR/Kconfig
    rm -rf SukiSU-Ultra  && rm -rf "$DRIVER_DIR/kernelsu"

    #安装 SukiSU b8f9a4(支持的最后一版):
    unzip -o Patchs/SukiSU-Ultra-b8f9a4.zip -d SukiSU-Ultra
    ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$KERNEL_SOURCE/SukiSU-Ultra/kernel")" "$DRIVER_DIR/kernelsu" && echo "[+] Symlink created."
    grep -q "kernelsu" "$DRIVER_MAKEFILE" || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE" && echo "[+] Modified Makefile."
    grep -q "source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG" || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG" && echo "[+] Modified Kconfig."

    echo "Setup patches for SukiSU (为 SukiSU 安装补丁)"
    #SUSFS for SukiSU 补丁：
    unzip -o Patchs/Susfs4ksu-98fad0.zip -d Susfs4ksu
    cp Susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch ./
    cp Susfs4ksu/kernel_patches/fs/* ./fs/
    cp Susfs4ksu/kernel_patches/include/linux/* ./include/linux/
    patch -p1 -F 3 < 50_add_susfs_in_kernel-4.19.patch || true
          
    #内核钩子补丁：
    unzip -o Patchs/SukiSU_patch-83aa64b.zip -d SukiSU_patch
    cp SukiSU_patch/4.19/ksu_hooks_sukisu_4.19.patch ./
    patch -p1 -F 3 < ksu_hooks_sukisu_4.19.patch || true
          
    #特征隐藏补丁：
    cp SukiSU_patch/69_hide_stuff.patch ./
    patch -p1 -F 3 < 69_hide_stuff.patch || true    

    echo "SukiSU 补丁完成！"
else
    echo "KSU is disabled"
fi

echo "🛠️ 正在为内核安装 LXC 补丁..."
cd $KERNEL_SOURCE
            
rm -rf utils && unzip -o Patchs/LXC_utils.zip -d utils

echo 'source "utils/Kconfig"' >> "Kconfig" 
echo "CONFIG_DOCKER=y" >> arch/arm64/configs/${TARGET_DEVICE}_defconfig
 
sed -i '/CONFIG_ANDROID_PARANOID_NETWORK/d' arch/arm64/configs/${TARGET_DEVICE}_defconfig
echo "# CONFIG_ANDROID_PARANOID_NETWORK is not set" >> arch/arm64/configs/${TARGET_DEVICE}_defconfig
 
chmod +x $KERNEL_SOURCE/utils/runcpatch.sh
 
if [ -f $KERNEL_SOURCE/kernel/cgroup/cgroup.c ]; then
    sh $KERNEL_SOURCE/utils/runcpatch.sh $KERNEL_SOURCE/kernel/cgroup/cgroup.c
fi
 
if [ -f $KERNEL_SOURCE/kernel/cgroup.c ]; then
    sh $KERNEL_SOURCE/utils/runcpatch.sh $KERNEL_SOURCE/kernel/cgroup.c
fi
 
if [ -f $KERNEL_SOURCE/net/netfilter/xt_qtaguid.c ]; then
    patch -p0 < $KERNEL_SOURCE/utils/xt_qtaguid.patch
fi

echo "LXC 补丁安装完成！"

echo "Cleaning..."

rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing kernel (repo: https://github.com/liyafe1997/AnyKernel3)"
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

# Add date to local version
local_version_str="-perf"
local_version_date_str="-$(date +%Y%m%d)-${GIT_COMMIT_ID}-perf"

sed -i "s/${local_version_str}/${local_version_date_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

if [ $BUILD_AOSP -eq 0 ]; then
echo "🛠️ Applying MIUI specific DTS modifications... (应用 MIUI 特定的 DTS 修改)"

dts_source=arch/arm64/boot/dts/vendor/qcom
git restore --source=HEAD -- ${dts_source}

# Correct panel dimensions on MIUI builds
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2*
sed -i 's/<155>/<1544>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<155>/<1545>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j2*

# Enable back mi smartfps while disabling qsync min refresh-rate
sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*

# Enable back refresh rates supported on MIUI
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi

# Enable back brightness control from dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi

fi

make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

echo "🔧 Applying basic optimized configurations... (应用基本优化配置)"
scripts/config --file out/.config \
  -e KALLSYMS \
  -e KALLSYMS_ALL \
  -e KPROBES \
  -e HAVE_KPROBES \
  -e KPROBE_EVENTS \
  -e TMPFS_XATTR=y \
  -e TMPFS_POSIX_ACL \
  -e IP_NF_TARGET_TTL \
  -e IP6_NF_TARGET_HL \
  -e IP6_NF_MATCH_HL \
  -e UCLAMP_TASK \
  -e TCP_CONG_ADVANCED \
  -e TCP_CONG_BIC \
  -e TCP_CONG_CUBIC \
  -e TCP_CONG_WESTWOOD \
  -e TCP_CONG_HTCP \
  -e TCP_CONG_HSTCP \
  -e TCP_CONG_HYBLA \
  -e TCP_CONG_VEGAS \
  -e TCP_CONG_NV \
  -e TCP_CONG_SCALABLE \
  -e TCP_CONG_LP \
  -e TCP_CONG_VENO \
  -e TCP_CONG_YEAH \
  -e TCP_CONG_ILLINOIS \
  -e TCP_CONG_DCTCP \
  -e TCP_CONG_CDG \
  -e TCP_CONG_BBR \
  -e DEFAULT_BBR \
  -e NET_SCHED \
  -e NET_SCH_HTB \
  -e NET_SCH_HFSC \
  -e NET_SCH_PRIO \
  -e NET_SCH_MULTIQ \
  -e NET_SCH_RED \
  -e NET_SCH_SFB \
  -e NET_SCH_SFQ \
  -e NET_SCH_TEQL \
  -e NET_SCH_TBF \
  -e NET_SCH_CBS \
  -e NET_SCH_ETF \
  -e NET_SCH_TAPRIO \
  -e NET_SCH_GRED \
  -e NET_SCH_NETEM \
  -e NET_SCH_DRR \
  -e NET_SCH_MQPRIO \
  -e NET_SCH_SKBPRIO \
  -e NET_SCH_CHOKE \
  -e NET_SCH_QFQ \
  -e NET_SCH_CODEL \
  -e NET_SCH_FQ_CODEL \
  -e NET_SCH_CAKE \
  -e NET_SCH_FQ \
  -e NET_SCH_HHF \
  -e NET_SCH_PIE \
  -e NET_SCH_FQ_PIE \
  -e NET_SCH_INGRESS \
  -e NET_SCH_PLUG \
  -e NET_SCH_ETS \
  -e NET_SCH_FIFO \
  -e NET_SCH_DEFAULT \
  -e DEFAULT_FQ \
  -e MQ_IOSCHED_DEADLINE \
  -e MQ_IOSCHED_KYBER \
  -e IOSCHED_BFQ \
  -e BFQ_GROUP_IOSCHED \
  -e ENERGY_MODEL \
  -e CPU_IDLE \
  -e CPU_IDLE_GOV_MENU \
  -e CPU_IDLE_GOV_TEO \
  -e ARM_PSCI_CPUIDLE \
  -e CPU_FREQ \
  -e CPU_FREQ_STAT \
  -e CPU_FREQ_TIMES \
  -e CPU_FREQ_GOV_POWERSAVE \
  -e CPU_FREQ_GOV_CONSERVATIVE \
  -e CPU_FREQ_GOV_USERSPACE \
  -e CPU_FREQ_GOV_ONDEMAND \
  -e ZRAM \
  -e ZSMALLOC \
  -e ZRAM_WRITEBACK \
  -e CRYPTO_LZ4 \
  -e CRYPTO_LZ4HC \
  -e CRYPTO_LZ4K \
  -e CRYPTO_LZ4KD \
  -e CRYPTO_ZSTD \
  -e CRYPTO_842 \
  -e CRYPTO_LZO \
  -e CRYPTO_DEFLATE \
  -e ZRAM_DEF_COMP_LZ4KD \
  -e SWAP \
  -e ZSWAP \
  -e ANDROID_SIMPLE_LMK \
  -e CPU_FREQ_GOV_SCHEDHORIZON \
  -e CPU_FREQ_DEFAULT_GOV_SCHEDHORIZON \
  --set-val LITTLE_CPU_MASK 15 \
  --set-val BIG_CPU_MASK 112 \
  --set-val PRIME_CPU_MASK 128 \
  -e LRU_GEN \
  -e LRU_GEN_ENABLED \
  -e NTFS_FS \
  -e NTFS_RW \
  -e EXFAT_FS \
  -e EROFS_FS \
  -e EROFS_FS_XATTR \
  -e EROFS_FS_ZIP \
  -d ANDROID_PARANOID_NETWORK \
  -e PSTORE_LAST_KMSG 

# 添加 KSU 配置
if [ $KSU_ENABLE -eq 1 ]; then
	echo "🔧 Applying SukiSU-Ultra Configuration... (应用 SukiSU-Ultra 配置)"
    scripts/config --file out/.config \
    -e KSU \
    -e KSU_MANUAL_HOOK \
    -e KSU_SUSFS_HAS_MAGIC_MOUNT \
    -d KSU_SUSFS_SUS_PATH \
    -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT \
    -d KSU_SUSFS_SUS_OVERLAYFS \
    -e KSU_SUSFS_TRY_UMOUNT \
    -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
    -e KSU_SUSFS_SPOOF_UNAME \
    -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -d KSU_SUSFS_OPEN_REDIRECT \
    -d KSU_SUSFS_SUS_SU \
    -e KPM
else
    scripts/config --file out/.config -d KSU
fi

if [ $BUILD_AOSP -eq 0 ]; then
    echo "🔧 Apply MIUI specific configurations... (应用 MIUI 特定配置)"
    scripts/config --file out/.config \
        --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
        -e PERF_CRITICAL_RT_TASK	\
        -e SF_BINDER		\
        -e OVERLAY_FS		\
        -d DEBUG_FS \
        -e MIGT \
        -e MIGT_ENERGY_MODEL \
        -e MIHW \
        -e PACKAGE_RUNTIME_INFO \
        -e BINDER_OPT \
        -e KPERFEVENTS \
        -e MILLET \
        -d PERF_HUMANTASK \
        -d LTO_CLANG \
        -d LOCALVERSION_AUTO \
        -e SF_BINDER \
        -e XIAOMI_MIUI \
        -d MI_MEMORY_SYSFS \
        -e TASK_DELAY_ACCT \
        -e MIUI_ZRAM_MEMORY_TRACKING \
        -d CONFIG_MODULE_SIG_SHA512 \
        -d CONFIG_MODULE_SIG_HASH \
        -e MI_FRAGMENTION \
        -e PERF_HELPER \
        -e BOOTUP_RECLAIM \
        -e MI_RECLAIM \
        -e RTMM
fi

# for debug
# make $MAKE_ARGS V=1 -j1
make $MAKE_ARGS -j$(nproc)

if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "The file [out/arch/arm64/boot/Image] exists. Build successfully."
else
    echo "The file [out/arch/arm64/boot/Image] does not exist. Seems build failed."
    exit 1
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/

cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

if [ $BUILD_AOSP -eq 0 ]; then
    echo "Build for MIUI finished."
else
    echo "Build for AOSP finished."
fi

# Restore local version string
git restore --source=HEAD -- arch/arm64/configs/${TARGET_DEVICE}_defconfig

# sed -i "s/${local_version_date_str}/${local_version_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

if [ $KSU_ENABLE -eq 1 ]; then
    echo "🛠️ 正在修补 Image 文件..."
    kpmDst="anykernel/kernels"
    cp SukiSU_patch/kpm/patch_linux "$kpmDst/patch"
    cd "$kpmDst"
    chmod 777 patch && ./patch
    rm -f patch
    if [ $? -eq 0 ]; then
        rm -f Image
        mv oImage Image   
        echo "✅ Image file repair complete (Image 文件修补完成)"
    else
        echo "❌ KPM Patch Failed, Use Original Image (KPM 修补失败，使用原始 Image)"
    fi
    cd "$KERNEL_SOURCE"
    echo "🛠️ 正在清理补丁文件..."
    rm -rf *.patch Susfs4ksu SukiSU_patch SukiSU-Ultra
fi

cd anykernel 

if [ $BUILD_AOSP -eq 0 ]; then
    ZIP_FILENAME=Kernel_MIUI_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
else
    ZIP_FILENAME=Kernel_AOSP_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
fi

zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip

mv $ZIP_FILENAME ../

cd ..

echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
