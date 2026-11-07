// iosem native core.
//
// This translation unit is intentionally small: it proves the JNI/NDK
// pipeline and reports what the device can actually do. The QEMU backend is a
// separate executable packaged in nativeLibraryDir and launched by QemuRunner.

#include <jni.h>
#include <android/log.h>

#include <dirent.h>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#define LOG_TAG "iosem-core"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace {

std::string fromJString(JNIEnv *env, jstring value) {
    if (value == nullptr) return {};
    const char *chars = env->GetStringUTFChars(value, nullptr);
    std::string out = chars != nullptr ? chars : "";
    if (chars != nullptr) env->ReleaseStringUTFChars(value, chars);
    return out;
}

bool fileExists(const std::string &path) {
    struct stat st {};
    return ::stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_dev_iosem_core_NativeCore_version(JNIEnv *env, jobject /*this*/) {
    return env->NewStringUTF("0.3.0");
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_iosem_core_NativeCore_capabilities(JNIEnv *env, jobject /*this*/) {
    std::ostringstream out;

#if defined(__aarch64__)
    out << "abi=arm64-v8a";
#elif defined(__x86_64__)
    out << "abi=x86_64";
#elif defined(__arm__)
    out << "abi=armeabi-v7a";
#else
    out << "abi=unknown";
#endif

    const long pageSize = ::sysconf(_SC_PAGESIZE);
    const long cpus = ::sysconf(_SC_NPROCESSORS_ONLN);
    const long pages = ::sysconf(_SC_PHYS_PAGES);

    out << "\npage_size=" << pageSize;
    out << "\ncpus=" << cpus;
    if (pages > 0 && pageSize > 0) {
        out << "\nram_mib=" << (pages * pageSize) / (1024L * 1024L);
    }

    out << "\nkvm=" << (::access("/dev/kvm", R_OK | W_OK) == 0
                            ? "present (not usable from an unprivileged Android app)"
                            : "absent");
    out << "\nbackend=tcg";
    out << "\nqemu=external native executable (Console tab)";
    out << "\nmachine=iPhone6splus-n66-s8000";
    out << "\nxnu_platform=apple-arm64 (device tree + boot_args required)";
    out << "\nnote=generic QEMU virt is not a supported XNU platform";

    LOGI("capabilities queried");
    return env->NewStringUTF(out.str().c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_iosem_core_NativeCore_probeBoot(JNIEnv *env, jobject /*this*/, jstring artifactDir) {
    const std::string dir = fromJString(env, artifactDir);
    const char *const expected[] = {
        "kernelcache.release.n66.out",
        "DeviceTree.n66ap.im4p.out",
        "aleph_bdev_drv.bin",
        "hfs.main",
        "hfs.sec",
        "048-32651-104.dmg.out",
    };

    std::ostringstream out;
    out << "probe " << (dir.empty() ? "(none)" : dir) << "\n";

    if (dir.empty() || ::access(dir.c_str(), R_OK) != 0) {
        out << "  directory is not readable\n";
        return env->NewStringUTF(out.str().c_str());
    }

    for (const char *name : expected) {
        const std::string path = dir + "/" + name;
        if (fileExists(path)) {
            struct stat st {};
            ::stat(path.c_str(), &st);
            out << "  [ok] " << name << "  " << static_cast<long long>(st.st_size) << " bytes\n";
        } else {
            out << "  [--] " << name << "\n";
        }
    }

    out << "\nThe machine is launched from the Console tab.";
    out << "\nProbing only inspects files; it executes nothing.";
    return env->NewStringUTF(out.str().c_str());
}
