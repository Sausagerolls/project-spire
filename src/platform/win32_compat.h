// Minimal stand-ins for the Win32 APIs used by the opt-in diagnostics in
// src/diagnostics, so they build on macOS and Linux. Only what those headers
// use is provided.
//
// SEH has no POSIX equivalent here: __try/__except become plain blocks, so a
// diagnostic that faults while probing memory crashes instead of skipping the
// page. The diagnostics check pages with VirtualQuery first, which limits that.

#ifndef FABLE2_WIN32_COMPAT_H
#define FABLE2_WIN32_COMPAT_H

#ifdef _WIN32
#error "win32_compat.h is for non-Windows builds"
#endif

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <pthread.h>
#include <sys/mman.h>
#include <thread>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_vm.h>
#else
#include <cstdio>
#include <cstring>
#endif

using DWORD = uint32_t;
using LPVOID = void*;
using HANDLE = void*;
using SIZE_T = size_t;
#define WINAPI
#define MAX_PATH 260

constexpr DWORD MEM_COMMIT = 0x1000;
constexpr DWORD MEM_RESERVE = 0x2000;
constexpr DWORD MEM_FREE = 0x10000;
constexpr DWORD PAGE_NOACCESS = 0x01;
constexpr DWORD PAGE_READONLY = 0x02;
constexpr DWORD PAGE_READWRITE = 0x04;
constexpr DWORD PAGE_WRITECOPY = 0x08;
constexpr DWORD PAGE_EXECUTE_READ = 0x20;
constexpr DWORD PAGE_EXECUTE_READWRITE = 0x40;
constexpr DWORD PAGE_GUARD = 0x100;
constexpr int EXCEPTION_EXECUTE_HANDLER = 1;

#define __try if (true)
#define __except(filter) else if (false)
#define __declspec(attr) __attribute__((attr))

struct MEMORY_BASIC_INFORMATION
{
    void* BaseAddress;
    void* AllocationBase;
    DWORD AllocationProtect;
    SIZE_T RegionSize;
    DWORD State;
    DWORD Protect;
    DWORD Type;
};

inline DWORD Win32ProtectFromPosix(bool read, bool write, bool execute)
{
    if (execute)
        return write ? PAGE_EXECUTE_READWRITE : PAGE_EXECUTE_READ;
    if (write)
        return PAGE_READWRITE;
    return read ? PAGE_READONLY : PAGE_NOACCESS;
}

// Describes the mapping that contains `address`, or the free gap before the
// next mapping. Returns 0 if nothing is mapped at or after it.
inline SIZE_T VirtualQuery(const void* address, MEMORY_BASIC_INFORMATION* info, SIZE_T length)
{
    if (info == nullptr || length < sizeof(MEMORY_BASIC_INFORMATION))
        return 0;
#if defined(__APPLE__)
    mach_vm_address_t region = reinterpret_cast<mach_vm_address_t>(address);
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t basic{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (mach_vm_region(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
            reinterpret_cast<vm_region_info_t>(&basic), &count, &object) != KERN_SUCCESS)
        return 0;
    const auto requested = reinterpret_cast<mach_vm_address_t>(address);
    if (region > requested)
    {
        // `address` is in a gap; report the gap up to the next mapping.
        *info = { const_cast<void*>(address), nullptr, 0, SIZE_T(region - requested), MEM_FREE, PAGE_NOACCESS, 0 };
        return sizeof(MEMORY_BASIC_INFORMATION);
    }
    const DWORD protect = Win32ProtectFromPosix(basic.protection & VM_PROT_READ, basic.protection & VM_PROT_WRITE,
        basic.protection & VM_PROT_EXECUTE);
    *info = { reinterpret_cast<void*>(region), reinterpret_cast<void*>(region), protect, SIZE_T(size), MEM_COMMIT,
        protect, 0 };
    return sizeof(MEMORY_BASIC_INFORMATION);
#else
    // Linux: find the mapping in /proc/self/maps.
    const uintptr_t target = reinterpret_cast<uintptr_t>(address);
    FILE* maps = fopen("/proc/self/maps", "r");
    if (maps == nullptr)
        return 0;
    unsigned long start, end;
    char perms[8];
    SIZE_T result = 0;
    while (fscanf(maps, "%lx-%lx %7s %*[^\n]", &start, &end, perms) == 3)
    {
        if (target >= start && target < end)
        {
            const DWORD protect = Win32ProtectFromPosix(perms[0] == 'r', perms[1] == 'w', perms[2] == 'x');
            *info = { reinterpret_cast<void*>(start), reinterpret_cast<void*>(start), protect, SIZE_T(end - start),
                MEM_COMMIT, protect, 0 };
            result = sizeof(MEMORY_BASIC_INFORMATION);
            break;
        }
    }
    fclose(maps);
    return result;
#endif
}

inline void* VirtualAlloc(void* address, SIZE_T size, DWORD type, DWORD protect)
{
    int prot = PROT_NONE;
    if (protect == PAGE_READWRITE || protect == PAGE_WRITECOPY)
        prot = PROT_READ | PROT_WRITE;
    else if (protect == PAGE_READONLY)
        prot = PROT_READ;
    const int flags = MAP_PRIVATE | MAP_ANON | (address ? MAP_FIXED : 0);
    void* result = mmap(address, size, prot, flags, -1, 0);
    return result == MAP_FAILED ? nullptr : result;
}

inline void Sleep(DWORD milliseconds)
{
    std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
}

inline DWORD GetCurrentThreadId()
{
#if defined(__APPLE__)
    return DWORD(pthread_mach_thread_np(pthread_self()));
#else
    return DWORD(pthread_self());
#endif
}

// Detached thread; the returned handle is only meaningful as "non-null".
inline HANDLE CreateThread(void*, SIZE_T, DWORD (*start)(LPVOID), LPVOID parameter, DWORD, DWORD*)
{
    std::thread([start, parameter] { start(parameter); }).detach();
    return reinterpret_cast<HANDLE>(1);
}

#endif // FABLE2_WIN32_COMPAT_H
