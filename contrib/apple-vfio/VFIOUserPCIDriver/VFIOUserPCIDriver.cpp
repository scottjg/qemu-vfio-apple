//
//  VFIOUserPCIDriver.cpp
//  VFIOUserPCIDriver
//
//  Created by scottjg on 3/18/26.
//

#include <os/log.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include <DriverKit/OSMetaClass.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOMemoryMap.h>
#include <DriverKit/IODMACommand.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOInterruptDispatchSource.h>
#include <DriverKit/IODispatchQueue.h>
#include <PCIDriverKit/IOPCIDevice.h>
#include <PCIDriverKit/IOPCIFamilyDefinitions.h>

#include "VFIOUserPCIDriver.h"
#include "VFIOUserPCIDriverUserClient.h"

enum {
    kVFIOUserPCIDriverUserClientMethodGetIdentity = 0,
    kVFIOUserPCIDriverUserClientMethodClaim = 1,
    kVFIOUserPCIDriverUserClientMethodTerminate = 2,
    kVFIOUserPCIDriverUserClientMethodAllocateDMABuffer = 3,
    kVFIOUserPCIDriverUserClientMethodFreeDMABuffer = 4,
    kVFIOUserPCIDriverUserClientMethodRegisterDMARegion = 5,
    kVFIOUserPCIDriverUserClientMethodUnregisterDMARegion = 6,
    kVFIOUserPCIDriverUserClientMethodProbeDMARegion = 7,
    kVFIOUserPCIDriverUserClientMethodConfigRead = 8,
    kVFIOUserPCIDriverUserClientMethodConfigWrite = 9,
    kVFIOUserPCIDriverUserClientMethodGetBARInfo = 10,
    kVFIOUserPCIDriverUserClientMethodMMIORead = 11,
    kVFIOUserPCIDriverUserClientMethodMMIOWrite = 12,
    kVFIOUserPCIDriverUserClientMethodSetupInterrupts = 13,
    kVFIOUserPCIDriverUserClientMethodCheckInterrupt = 14,
    kVFIOUserPCIDriverUserClientMethodWaitInterrupt = 15,
    kVFIOUserPCIDriverUserClientMethodSetIRQMask = 16,
    kVFIOUserPCIDriverUserClientMethodResetDevice = 17,
};

enum {
    kVFIOUserPCIDriverUserClientMemoryTypeDMABuffer = 0,
    kVFIOUserPCIDriverUserClientMemoryTypeBAR0 = 1,
    kVFIOUserPCIDriverUserClientMemoryTypeBAR1 = 2,
    kVFIOUserPCIDriverUserClientMemoryTypeBAR2 = 3,
    kVFIOUserPCIDriverUserClientMemoryTypeBAR3 = 4,
    kVFIOUserPCIDriverUserClientMemoryTypeBAR4 = 5,
    kVFIOUserPCIDriverUserClientMemoryTypeBAR5 = 6,
    kVFIOUserPCIDriverUserClientMemoryTypeIRQState = 7,
};

/*
 * Keep enough live DMA region slots for large bring-up bursts while we map
 * page-sized control requests one-by-one.
 */
#define VFIO_USER_MAX_CLIENT_DMA_REGIONS 65536
#define VFIO_USER_MAX_CLIENT_DMA_CHUNKS 128
#define VFIO_USER_DMA_CHUNK_SIZE (1536ULL * 1024ULL * 1024ULL)
#define VFIO_USER_MAX_DMA_SEGMENTS 32
#define VFIO_USER_MAX_IRQ_VECTORS 256
#define VFIO_USER_IRQ_PENDING_WORDS 4  /* 4 × 64 = 256 vectors */

struct VFIOUserClientDMAChunk {
    bool valid;
    uint64_t iova;
    uint64_t size;
    IOMemoryDescriptor *memoryDescriptor;
    IODMACommand *dmaCommand;
};

struct VFIOUserClientDMARegion {
    bool valid;
    uint64_t iova;
    uint64_t size;
    uint32_t chunkCount;
    uint64_t firstBusAddress;
    uint64_t firstBusLength;
    VFIOUserClientDMAChunk chunks[VFIO_USER_MAX_CLIENT_DMA_CHUNKS];
};

struct VFIOUserPCIDriver_IVars {
    bool providerClaimed;
    uint32_t providerClaimRefs;
    VFIOUserPCIDriverUserClient *openerClient;
};

struct VFIOUserPCIDriverUserClient_IVars {
    bool claimed;
    IOBufferMemoryDescriptor *dmaBuffer;
    IODMACommand *dmaCommand;
    uint64_t dmaBufferSize;
    uint64_t dmaFlags;
    uint32_t dmaSegmentsCount;
    IOAddressSegment dmaSegments[32];
    VFIOUserClientDMARegion clientDMARegions[VFIO_USER_MAX_CLIENT_DMA_REGIONS];
    uint64_t activeDMARegionCount;
    uint64_t activeDMAChunkCount;
    uint64_t activeDMABytes;
    uint64_t peakDMARegionCount;
    uint64_t peakDMAChunkCount;
    uint64_t peakDMABytes;
    uint64_t dmaCompleteFailureCount;

    bool interruptsSetUp;
    uint32_t numInterrupts;
    IOInterruptDispatchSource *interruptSources[VFIO_USER_MAX_IRQ_VECTORS];
    IODispatchQueue *irqQueue;

    /*
     * IRQ pending/enabled bitmaps live in a shared page that the client
     * can map via IOConnectMapMemory64 (memory type kMemoryTypeIRQState).
     * The pointers below reference into that page so both the dext and
     * the client operate on the same cache lines without Mach IPC.
     *
     * Layout of the shared page (64 bytes used):
     *   [0x00..0x1F]  irqPending[4]  — dext sets bits, client clears
     *   [0x20..0x3F]  irqEnabled[4]  — client writes, dext reads
     */
    IOBufferMemoryDescriptor *irqSharedBuffer;
    volatile uint64_t *irqPending;   /* -> shared page offset 0x00 */
    volatile uint64_t *irqEnabled;   /* -> shared page offset 0x20 */
    OSAction *pendingInterruptNotify;
};

struct VFIOUserPCIDeviceIdentity {
    uint8_t bus;
    uint8_t device;
    uint8_t function;
    uint16_t vendorID;
    uint16_t deviceID;
    uint32_t classCode;
};

static double
vfio_user_dma_bytes_to_mb(uint64_t bytes)
{
    return (double)bytes / (1024.0 * 1024.0);
}

static void
vfio_user_dma_log(const char *fmt, ...)
{
    char message[1024];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(message, sizeof(message), fmt, ap);
    va_end(ap);

    IOLog("vfio-user-dext: %s\n", message);
    os_log(OS_LOG_DEFAULT, "vfio-user-dext: %{public}s", message);
}

static void
vfio_user_note_dma_region_added(VFIOUserPCIDriverUserClient *client,
                                uint64_t size,
                                uint32_t chunkCount)
{
    if (client == nullptr || client->ivars == nullptr) {
        return;
    }

    client->ivars->activeDMARegionCount++;
    client->ivars->activeDMAChunkCount += chunkCount;
    client->ivars->activeDMABytes += size;

    if (client->ivars->activeDMARegionCount > client->ivars->peakDMARegionCount) {
        client->ivars->peakDMARegionCount = client->ivars->activeDMARegionCount;
    }
    if (client->ivars->activeDMAChunkCount > client->ivars->peakDMAChunkCount) {
        client->ivars->peakDMAChunkCount = client->ivars->activeDMAChunkCount;
    }
    if (client->ivars->activeDMABytes > client->ivars->peakDMABytes) {
        client->ivars->peakDMABytes = client->ivars->activeDMABytes;
    }
}

static void
vfio_user_note_dma_region_removed(VFIOUserPCIDriverUserClient *client,
                                  uint64_t size,
                                  uint32_t chunkCount)
{
    if (client == nullptr || client->ivars == nullptr) {
        return;
    }

    if (client->ivars->activeDMARegionCount > 0) {
        client->ivars->activeDMARegionCount--;
    }
    if (client->ivars->activeDMAChunkCount >= chunkCount) {
        client->ivars->activeDMAChunkCount -= chunkCount;
    } else {
        client->ivars->activeDMAChunkCount = 0;
    }
    if (client->ivars->activeDMABytes >= size) {
        client->ivars->activeDMABytes -= size;
    } else {
        client->ivars->activeDMABytes = 0;
    }
}

static kern_return_t
vfio_user_release_dma_region_chunks(VFIOUserPCIDriverUserClient *client,
                                    VFIOUserClientDMARegion *region)
{
    kern_return_t firstFailure = kIOReturnSuccess;

    if (client == nullptr || client->ivars == nullptr || region == nullptr) {
        return kIOReturnBadArgument;
    }

    for (uint32_t chunkIdx = 0; chunkIdx < region->chunkCount; chunkIdx++) {
        VFIOUserClientDMAChunk *chunk = &region->chunks[chunkIdx];

        if (chunk->dmaCommand != nullptr) {
            kern_return_t ret;

            ret = chunk->dmaCommand->CompleteDMA(
                kIODMACommandCompleteDMANoOptions);
            if (ret != kIOReturnSuccess) {
                client->ivars->dmaCompleteFailureCount++;
                if (firstFailure == kIOReturnSuccess) {
                    firstFailure = ret;
                }
                vfio_user_dma_log(
                    "CompleteDMA failed region=%#llx chunk=%#llx size=%llu "
                    "index=%u kr=%#x active_regions=%llu active_chunks=%llu "
                    "active_bytes=%.1f MB complete_failures=%llu",
                    region->iova,
                    chunk->iova,
                    chunk->size,
                    (unsigned int)chunkIdx,
                    ret,
                    client->ivars->activeDMARegionCount,
                    client->ivars->activeDMAChunkCount,
                    vfio_user_dma_bytes_to_mb(client->ivars->activeDMABytes),
                    client->ivars->dmaCompleteFailureCount);
            }

            chunk->dmaCommand->release();
            chunk->dmaCommand = nullptr;
        }

        if (chunk->memoryDescriptor != nullptr) {
            chunk->memoryDescriptor->release();
            chunk->memoryDescriptor = nullptr;
        }

        chunk->valid = false;
    }

    return firstFailure;
}

static const char *
vfio_user_bar_type_string(uint8_t barType)
{
    switch (barType) {
    case kPCIBARTypeM32:
        return "mem32";
    case kPCIBARTypeIO:
        return "io";
    case kPCIBARTypeM64:
        return "mem64";
    case kPCIBARTypeM32PF:
        return "mem32-prefetch";
    case kPCIBARTypeM64PF:
        return "mem64-prefetch";
    default:
        return "unknown";
    }
}

/*
 * BAR memory descriptor cache.  Populated by the first (claimed) user client
 * when CopyClientMemoryForType is called for a BAR type.  Subsequent
 * (unclaimed) user clients reuse the cached descriptors so they can map BARs
 * via IOConnectMapMemory64 without needing their own IOPCIDevice Open().
 */
static IOMemoryDescriptor *g_barDescCache[6] = {};

static IOPCIDevice *
vfio_user_get_pci_device(IOService *service)
{
    if (service == nullptr) {
        return nullptr;
    }

    IOService *provider = service->GetProvider();
    IOPCIDevice *typedProvider = OSDynamicCast(IOPCIDevice, provider);
    return typedProvider;
}

static kern_return_t
vfio_user_read_identity(IOService *service, VFIOUserPCIDeviceIdentity *identity)
{
    if (service == nullptr || identity == nullptr) {
        return kIOReturnBadArgument;
    }

    IOPCIDevice *pciDevice = vfio_user_get_pci_device(service);
    if (pciDevice == nullptr) {
        return kIOReturnUnsupported;
    }

    identity->bus = 0;
    identity->device = 0;
    identity->function = 0;
    identity->vendorID = 0xffff;
    identity->deviceID = 0xffff;
    identity->classCode = 0xffffffff;

    kern_return_t ret = pciDevice->GetBusDeviceFunction(&identity->bus,
                                                        &identity->device,
                                                        &identity->function);
    if (ret != kIOReturnSuccess) {
        return ret;
    }

    pciDevice->ConfigurationRead16(kIOPCIConfigurationOffsetVendorID, &identity->vendorID);
    pciDevice->ConfigurationRead16(kIOPCIConfigurationOffsetDeviceID, &identity->deviceID);
    pciDevice->ConfigurationRead32(kIOPCIConfigurationOffsetRevisionID, &identity->classCode);
    identity->classCode = (identity->classCode >> 8) & 0x00ffffffU;
    return kIOReturnSuccess;
}

static bool
vfio_user_service_claimed(VFIOUserPCIDriverUserClient *client)
{
    VFIOUserPCIDriver *driverService;

    if (client == nullptr) {
        return false;
    }

    driverService = OSDynamicCast(VFIOUserPCIDriver, client->GetProvider());
    return driverService != nullptr &&
           driverService->ivars != nullptr &&
           driverService->ivars->providerClaimed;
}

static kern_return_t
vfio_user_retain_shared_claim(VFIOUserPCIDriverUserClient *client,
                              IOService *driverService,
                              const VFIOUserPCIDeviceIdentity *identity)
{
    VFIOUserPCIDriver *driver;
    IOPCIDevice *pciDevice;
    kern_return_t ret;

    if (client == nullptr || client->ivars == nullptr || driverService == nullptr ||
        identity == nullptr) {
        return kIOReturnBadArgument;
    }

    driver = OSDynamicCast(VFIOUserPCIDriver, driverService);
    if (driver == nullptr || driver->ivars == nullptr) {
        return kIOReturnUnsupported;
    }

    if (client->ivars->claimed) {
        return kIOReturnSuccess;
    }

    pciDevice = vfio_user_get_pci_device(driverService);
    if (pciDevice == nullptr) {
        return kIOReturnUnsupported;
    }

    if (!driver->ivars->providerClaimed) {
        ret = pciDevice->Open(client, 0);
        if (ret != kIOReturnSuccess) {
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: failed to open PCI device for %02x:%02x.%u: %#x",
                   (unsigned int)identity->bus,
                   (unsigned int)identity->device,
                   (unsigned int)identity->function,
                   ret);
            return ret;
        }

        {
            uint16_t cmd = 0;
            uint16_t wanted;

            pciDevice->ConfigurationRead16(0x04, &cmd);
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: PCI command register after Open: %#x", cmd);
            wanted = cmd | 0x06; /* Memory Space Enable + Bus Master Enable */
            if (wanted != cmd) {
                pciDevice->ConfigurationWrite16(0x04, wanted);
                pciDevice->ConfigurationRead16(0x04, &cmd);
                os_log(OS_LOG_DEFAULT,
                       "vfio-user-dext: PCI command register after enable: %#x", cmd);
            }
        }

        driver->ivars->providerClaimed = true;
        driver->ivars->openerClient = client;
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: opened PCI device for %02x:%02x.%u (opener=primary client)",
               (unsigned int)identity->bus,
               (unsigned int)identity->device,
               (unsigned int)identity->function);

    } else {
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: secondary claim for %02x:%02x.%u (device already open)",
               (unsigned int)identity->bus,
               (unsigned int)identity->device,
               (unsigned int)identity->function);
    }

    driver->ivars->providerClaimRefs++;
    client->ivars->claimed = true;
    os_log(OS_LOG_DEFAULT,
           "vfio-user-dext: attached shared claim for %02x:%02x.%u refs=%u",
           (unsigned int)identity->bus,
           (unsigned int)identity->device,
           (unsigned int)identity->function,
           (unsigned int)driver->ivars->providerClaimRefs);
    return kIOReturnSuccess;
}

static void
vfio_user_release_shared_claim(VFIOUserPCIDriverUserClient *client)
{
    IOService *driverService;
    VFIOUserPCIDriver *driver;
    VFIOUserPCIDeviceIdentity identity;
    bool haveIdentity;
    bool isOpener;

    if (client == nullptr || client->ivars == nullptr || !client->ivars->claimed) {
        return;
    }

    client->ivars->claimed = false;
    driverService = client->GetProvider();
    driver = OSDynamicCast(VFIOUserPCIDriver, driverService);
    if (driver == nullptr || driver->ivars == nullptr) {
        return;
    }

    haveIdentity = driverService != nullptr &&
                   vfio_user_read_identity(driverService, &identity) == kIOReturnSuccess;

    if (driver->ivars->providerClaimRefs > 0) {
        driver->ivars->providerClaimRefs--;
    }

    isOpener = (driver->ivars->openerClient == client);

    if (isOpener && driver->ivars->providerClaimed) {
        /*
         * This client originally called Open() on the PCI device.
         * Close it now while the client object is still alive — IOPCIFamily
         * requires the Close entity to match the Open entity.
         */
        IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
        if (pciDevice != nullptr) {
            pciDevice->Close(client, 0);
        }
        driver->ivars->providerClaimed = false;
        driver->ivars->openerClient = nullptr;

        if (haveIdentity) {
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: primary client closed PCI device %02x:%02x.%u (remaining refs=%u)",
                   (unsigned int)identity.bus,
                   (unsigned int)identity.device,
                   (unsigned int)identity.function,
                   (unsigned int)driver->ivars->providerClaimRefs);
        }
    } else {
        if (haveIdentity) {
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: secondary client detached from %02x:%02x.%u refs=%u",
                   (unsigned int)identity.bus,
                   (unsigned int)identity.device,
                   (unsigned int)identity.function,
                   (unsigned int)driver->ivars->providerClaimRefs);
        }
    }
}

static void
vfio_user_release_dma_buffer(VFIOUserPCIDriverUserClient *client)
{
    if (client == nullptr || client->ivars == nullptr) {
        return;
    }

    if (client->ivars->dmaCommand != nullptr) {
        client->ivars->dmaCommand->CompleteDMA(kIODMACommandCompleteDMANoOptions);
    }

    OSSafeReleaseNULL(client->ivars->dmaCommand);
    OSSafeReleaseNULL(client->ivars->dmaBuffer);

    client->ivars->dmaBufferSize = 0;
    client->ivars->dmaFlags = 0;
    client->ivars->dmaSegmentsCount = 0;
    memset(client->ivars->dmaSegments, 0, sizeof(client->ivars->dmaSegments));
}

static kern_return_t
vfio_user_allocate_dma_buffer(VFIOUserPCIDriverUserClient *client,
                              uint64_t requestedSize,
                              uint64_t requestedAlignment)
{
    if (client == nullptr || client->ivars == nullptr) {
        return kIOReturnBadArgument;
    }

    if (!vfio_user_service_claimed(client)) {
        return kIOReturnNotOpen;
    }

    if (requestedSize == 0 || requestedSize > VFIO_USER_DMA_CHUNK_SIZE) {
        return kIOReturnBadArgument;
    }

    IOService *driverService = client->GetProvider();
    if (driverService == nullptr) {
        return kIOReturnNotAttached;
    }

    IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
    if (pciDevice == nullptr) {
        return kIOReturnUnsupported;
    }

    vfio_user_release_dma_buffer(client);

    uint64_t alignment = requestedAlignment;
    if (alignment == 0) {
        alignment = 4096;
    }

    IOBufferMemoryDescriptor *dmaBuffer = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionOutIn,
                                                         requestedSize,
                                                         alignment,
                                                         &dmaBuffer);
    if (ret != kIOReturnSuccess || dmaBuffer == nullptr) {
        return ret != kIOReturnSuccess ? ret : kIOReturnNoMemory;
    }

    ret = dmaBuffer->SetLength(requestedSize);
    if (ret != kIOReturnSuccess) {
        dmaBuffer->release();
        return ret;
    }

    IODMACommandSpecification specification = {};
    specification.options = kIODMACommandSpecificationNoOptions;
    specification.maxAddressBits = 64;

    IODMACommand *dmaCommand = nullptr;
    ret = IODMACommand::Create(pciDevice,
                               kIODMACommandCreateNoOptions,
                               &specification,
                               &dmaCommand);
    if (ret != kIOReturnSuccess || dmaCommand == nullptr) {
        dmaBuffer->release();
        return ret != kIOReturnSuccess ? ret : kIOReturnNoMemory;
    }

    uint64_t dmaFlags = 0;
    uint32_t dmaSegmentsCount = 32;
    ret = dmaCommand->PrepareForDMA(kIODMACommandPrepareForDMANoOptions,
                                    dmaBuffer,
                                    0,
                                    requestedSize,
                                    &dmaFlags,
                                    &dmaSegmentsCount,
                                    client->ivars->dmaSegments);
    if (ret != kIOReturnSuccess) {
        dmaCommand->release();
        dmaBuffer->release();
        return ret;
    }

    client->ivars->dmaBuffer = dmaBuffer;
    client->ivars->dmaCommand = dmaCommand;
    client->ivars->dmaBufferSize = requestedSize;
    client->ivars->dmaFlags = dmaFlags;
    client->ivars->dmaSegmentsCount = dmaSegmentsCount;

    VFIOUserPCIDeviceIdentity identity;
    if (vfio_user_read_identity(driverService, &identity) == kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: allocated DMA buffer size=%llu alignment=%llu segments=%u first=%#llx/%#llx for %02x:%02x.%u",
               requestedSize,
               alignment,
               (unsigned int)dmaSegmentsCount,
               dmaSegmentsCount > 0 ? client->ivars->dmaSegments[0].address : 0,
               dmaSegmentsCount > 0 ? client->ivars->dmaSegments[0].length : 0,
               (unsigned int)identity.bus,
               (unsigned int)identity.device,
               (unsigned int)identity.function);
    }

    return kIOReturnSuccess;
}

static kern_return_t
vfio_user_register_client_dma_region(VFIOUserPCIDriverUserClient *client,
                                     uint64_t iova,
                                     uint64_t clientVA,
                                     uint64_t size,
                                     uint32_t *outSegmentsCount,
                                     IOAddressSegment *outSegments,
                                     uint32_t maxSegments)
{
    if (client == nullptr || client->ivars == nullptr) {
        vfio_user_dma_log("register: bad client iova=%#llx size=%llu",
                          iova, size);
        return kIOReturnBadArgument;
    }

    if (!vfio_user_service_claimed(client)) {
        vfio_user_dma_log("register: service not claimed iova=%#llx size=%llu",
                          iova, size);
        return kIOReturnNotOpen;
    }

    if (size == 0 || clientVA == 0) {
        vfio_user_dma_log("register: bad args iova=%#llx va=%#llx size=%llu",
                          iova, clientVA, size);
        return kIOReturnBadArgument;
    }

    IOService *driverService = client->GetProvider();
    if (driverService == nullptr) {
        vfio_user_dma_log("register: no provider iova=%#llx size=%llu",
                          iova, size);
        return kIOReturnNotAttached;
    }

    IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
    if (pciDevice == nullptr) {
        vfio_user_dma_log("register: no PCI device iova=%#llx size=%llu",
                          iova, size);
        return kIOReturnUnsupported;
    }

    int freeSlot = -1;
    for (int i = 0; i < VFIO_USER_MAX_CLIENT_DMA_REGIONS; i++) {
        if (client->ivars->clientDMARegions[i].valid &&
            client->ivars->clientDMARegions[i].iova == iova) {
            /*
             * The guest driver owns uniqueness of iova and is expected to
             * coalesce/refcount duplicate maps on its side before they reach
             * the dext.  A duplicate arriving here is a guest bug; log it
             * loudly and refuse so the problem is visible.
             */
            vfio_user_dma_log(
                "register: duplicate iova=%#llx size=%llu existing_size=%llu",
                iova, size, client->ivars->clientDMARegions[i].size);
            return kIOReturnStillOpen;
        }
        if (!client->ivars->clientDMARegions[i].valid && freeSlot < 0) {
            freeSlot = i;
        }
    }

    if (freeSlot < 0) {
        vfio_user_dma_log("out of DMA region slots iova=%#llx size=%llu max=%u",
                          iova, size,
                          (unsigned int)VFIO_USER_MAX_CLIENT_DMA_REGIONS);
        return kIOReturnNoSpace;
    }

    if (outSegmentsCount == nullptr || outSegments == nullptr || maxSegments == 0) {
        vfio_user_dma_log("register: bad out params iova=%#llx size=%llu",
                          iova, size);
        return kIOReturnBadArgument;
    }

    uint64_t chunkCountNeeded =
        (size + VFIO_USER_DMA_CHUNK_SIZE - 1) / VFIO_USER_DMA_CHUNK_SIZE;
    if (chunkCountNeeded > VFIO_USER_MAX_CLIENT_DMA_CHUNKS) {
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: DMA region iova=%#llx size=%llu needs %llu chunks, max is %u",
               iova, size, chunkCountNeeded,
               (unsigned int)VFIO_USER_MAX_CLIENT_DMA_CHUNKS);
        *outSegmentsCount = 0;
        return kIOReturnNoSpace;
    }

    VFIOUserClientDMARegion *region = &client->ivars->clientDMARegions[freeSlot];
    memset(region, 0, sizeof(*region));
    region->iova = iova;
    region->size = size;

    IODMACommandSpecification specification = {};
    specification.options = kIODMACommandSpecificationNoOptions;
    specification.maxAddressBits = 64;

    uint64_t remaining = size;
    uint64_t chunkOffset = 0;
    uint32_t chunkCount = 0;
    kern_return_t ret = kIOReturnSuccess;

    while (remaining > 0) {
        uint64_t chunkSize = remaining > VFIO_USER_DMA_CHUNK_SIZE ?
                             VFIO_USER_DMA_CHUNK_SIZE : remaining;
        uint64_t chunkIOVA = iova + chunkOffset;
        uint64_t chunkClientVA = clientVA + chunkOffset;
        IOAddressSegment clientSegment;
        clientSegment.address = chunkClientVA;
        clientSegment.length = chunkSize;

        IOMemoryDescriptor *memDesc = nullptr;
        ret = client->CreateMemoryDescriptorFromClient(kIOMemoryDirectionOutIn,
                                                       1,
                                                       &clientSegment,
                                                       &memDesc);
        if (ret != kIOReturnSuccess || memDesc == nullptr) {
            vfio_user_dma_log(
                "CreateMemoryDescriptorFromClient failed iova=%#llx va=%#llx "
                "size=%llu: %#x",
                chunkIOVA, chunkClientVA, chunkSize, ret);
            ret = ret != kIOReturnSuccess ? ret : kIOReturnNoMemory;
            goto rollback;
        }

        IODMACommand *dmaCmd = nullptr;
        ret = IODMACommand::Create(pciDevice,
                                   kIODMACommandCreateNoOptions,
                                   &specification,
                                   &dmaCmd);
        if (ret != kIOReturnSuccess || dmaCmd == nullptr) {
            vfio_user_dma_log(
                "IODMACommand::Create failed iova=%#llx size=%llu kr=%#x "
                "active_regions=%llu active_chunks=%llu active_bytes=%.1f MB",
                chunkIOVA, chunkSize, ret,
                client->ivars->activeDMARegionCount,
                client->ivars->activeDMAChunkCount,
                vfio_user_dma_bytes_to_mb(client->ivars->activeDMABytes));
            memDesc->release();
            ret = ret != kIOReturnSuccess ? ret : kIOReturnNoMemory;
            goto rollback;
        }

        uint64_t dmaFlags = 0;
        uint32_t dmaSegmentsCount = VFIO_USER_MAX_DMA_SEGMENTS;
        IOAddressSegment dmaSegments[VFIO_USER_MAX_DMA_SEGMENTS];
        memset(dmaSegments, 0, sizeof(dmaSegments));
        /*
         * Pre-call breadcrumb: PrepareForDMA can panic the kernel from
         * inside IODARTMapper via a REQUIRE assert (see panic log
         * IODARTMapper.cpp:3375), so any logging *after* the call is
         * lost when DART rejects the request. Log the iova/size before
         * entering so the last dext line before a panic identifies the
         * exact chunk DART couldn't honour.
         */
        vfio_user_dma_log("PrepareForDMA enter iova=%#llx size=%llu "
                          "chunk_offset=%llu chunk=%u",
                          chunkIOVA, chunkSize, chunkOffset, chunkCount);
        ret = dmaCmd->PrepareForDMA(kIODMACommandPrepareForDMANoOptions,
                                    memDesc,
                                    0,
                                    chunkSize,
                                    &dmaFlags,
                                    &dmaSegmentsCount,
                                    dmaSegments);
        if (ret != kIOReturnSuccess) {
            vfio_user_dma_log(
                "PrepareForDMA failed iova=%#llx size=%llu kr=%#x "
                "active_regions=%llu active_chunks=%llu active_bytes=%.1f MB "
                "peak_regions=%llu peak_chunks=%llu peak_bytes=%.1f MB "
                "complete_failures=%llu max_regions=%u",
                chunkIOVA,
                chunkSize,
                ret,
                client->ivars->activeDMARegionCount,
                client->ivars->activeDMAChunkCount,
                vfio_user_dma_bytes_to_mb(client->ivars->activeDMABytes),
                client->ivars->peakDMARegionCount,
                client->ivars->peakDMAChunkCount,
                vfio_user_dma_bytes_to_mb(client->ivars->peakDMABytes),
                client->ivars->dmaCompleteFailureCount,
                (unsigned int)VFIO_USER_MAX_CLIENT_DMA_REGIONS);
            dmaCmd->release();
            memDesc->release();
            goto rollback;
        }

        /*
         * For the dynamic DART-aware path, allow DriverKit to choose the bus
         * address as long as the requested chunk resolves to one full-length
         * DMA segment. Keep rejecting fragmented or otherwise partial mappings
         * until the control protocol can return a richer segment list.
         */
        bool fullSingleSegment = dmaSegmentsCount == 1 &&
                                 dmaSegments[0].length == chunkSize;
        if (!fullSingleSegment) {
            uint64_t coveredLength = 0;

            for (uint32_t seg = 0; seg < dmaSegmentsCount; seg++) {
                if (dmaSegments[seg].length == 0 ||
                    coveredLength + dmaSegments[seg].length > chunkSize) {
                    break;
                }
                coveredLength += dmaSegments[seg].length;
            }

            vfio_user_dma_log(
                "rejecting DMA mapping iova=%#llx size=%llu segments=%u "
                "first=%#llx/%#llx covered=%llu",
                chunkIOVA, chunkSize, (unsigned int)dmaSegmentsCount,
                dmaSegmentsCount > 0 ? dmaSegments[0].address : 0,
                dmaSegmentsCount > 0 ? dmaSegments[0].length : 0,
                coveredLength);
            for (uint32_t seg = 0; seg < dmaSegmentsCount &&
                                    seg < VFIO_USER_MAX_DMA_SEGMENTS; seg++) {
                vfio_user_dma_log("DMA segment[%u] iova=%#llx actual=%#llx len=%#llx",
                                  (unsigned int)seg,
                                  chunkIOVA,
                                  dmaSegments[seg].address,
                                  dmaSegments[seg].length);
            }
            {
                kern_return_t completeRet;

                completeRet = dmaCmd->CompleteDMA(
                    kIODMACommandCompleteDMANoOptions);
                if (completeRet != kIOReturnSuccess) {
                    client->ivars->dmaCompleteFailureCount++;
                    vfio_user_dma_log(
                        "CompleteDMA failed while rejecting DMA mapping "
                        "iova=%#llx size=%llu kr=%#x complete_failures=%llu",
                        chunkIOVA, chunkSize, completeRet,
                        client->ivars->dmaCompleteFailureCount);
                }
            }
            dmaCmd->release();
            memDesc->release();
            ret = kIOReturnNotAligned;
            goto rollback;
        }

        VFIOUserClientDMAChunk *chunk = &region->chunks[chunkCount];
        chunk->valid = true;
        chunk->iova = chunkIOVA;
        chunk->size = chunkSize;
        chunk->memoryDescriptor = memDesc;
        chunk->dmaCommand = dmaCmd;

        if (chunkCount == 0) {
            region->firstBusAddress = dmaSegments[0].address;
            region->firstBusLength = dmaSegments[0].length;
        }

        chunkCount++;
        chunkOffset += chunkSize;
        remaining -= chunkSize;
    }

    region->valid = true;
    region->chunkCount = chunkCount;
    vfio_user_note_dma_region_added(client, size, chunkCount);

    *outSegmentsCount = 1;
    outSegments[0].address = region->firstBusAddress;
    outSegments[0].length = region->firstBusLength;

    return kIOReturnSuccess;

rollback:
    *outSegmentsCount = 0;
    for (uint32_t chunkIdx = 0; chunkIdx < chunkCount; chunkIdx++) {
        VFIOUserClientDMAChunk *chunk = &region->chunks[chunkIdx];
        if (chunk->dmaCommand != nullptr) {
            kern_return_t completeRet;

            completeRet = chunk->dmaCommand->CompleteDMA(
                kIODMACommandCompleteDMANoOptions);
            if (completeRet != kIOReturnSuccess) {
                client->ivars->dmaCompleteFailureCount++;
                vfio_user_dma_log(
                    "CompleteDMA failed during register rollback "
                    "region=%#llx chunk=%#llx size=%llu index=%u kr=%#x "
                    "complete_failures=%llu",
                    region->iova, chunk->iova, chunk->size,
                    (unsigned int)chunkIdx, completeRet,
                    client->ivars->dmaCompleteFailureCount);
            }
            chunk->dmaCommand->release();
        }
        if (chunk->memoryDescriptor != nullptr) {
            chunk->memoryDescriptor->release();
        }
    }
    memset(region, 0, sizeof(*region));
    return ret;
}

static kern_return_t
vfio_user_unregister_client_dma_region(VFIOUserPCIDriverUserClient *client,
                                       uint64_t iova)
{
    if (client == nullptr || client->ivars == nullptr) {
        return kIOReturnBadArgument;
    }

    for (int i = 0; i < VFIO_USER_MAX_CLIENT_DMA_REGIONS; i++) {
        VFIOUserClientDMARegion *region = &client->ivars->clientDMARegions[i];
        if (!region->valid || region->iova != iova) {
            continue;
        }

        kern_return_t releaseRet =
            vfio_user_release_dma_region_chunks(client, region);

        if (releaseRet != kIOReturnSuccess) {
            vfio_user_dma_log(
                "DMA region teardown saw CompleteDMA failure "
                "iova=%#llx size=%llu chunks=%u first_error=%#x",
                region->iova, region->size,
                (unsigned int)region->chunkCount, releaseRet);
        }

        vfio_user_note_dma_region_removed(client, region->size,
                                          region->chunkCount);

        memset(region, 0, sizeof(*region));
        return kIOReturnSuccess;
    }

    return kIOReturnNotFound;
}

static void
vfio_user_release_all_client_dma_regions(VFIOUserPCIDriverUserClient *client)
{
    if (client == nullptr || client->ivars == nullptr) {
        return;
    }

    for (int i = 0; i < VFIO_USER_MAX_CLIENT_DMA_REGIONS; i++) {
        VFIOUserClientDMARegion *region = &client->ivars->clientDMARegions[i];
        if (!region->valid) {
            continue;
        }

        kern_return_t releaseRet =
            vfio_user_release_dma_region_chunks(client, region);

        if (releaseRet != kIOReturnSuccess) {
            vfio_user_dma_log(
                "DMA region cleanup at client stop saw CompleteDMA failure "
                "iova=%#llx size=%llu chunks=%u first_error=%#x",
                region->iova, region->size,
                (unsigned int)region->chunkCount, releaseRet);
        }

        vfio_user_note_dma_region_removed(client, region->size,
                                          region->chunkCount);
        memset(region, 0, sizeof(*region));
    }
}

static kern_return_t
vfio_user_probe_client_dma_region(VFIOUserPCIDriverUserClient *client,
                                  uint64_t iova,
                                  uint64_t offset,
                                  uint64_t *outWord)
{
    if (client == nullptr || client->ivars == nullptr || outWord == nullptr) {
        return kIOReturnBadArgument;
    }

    for (int i = 0; i < VFIO_USER_MAX_CLIENT_DMA_REGIONS; i++) {
        VFIOUserClientDMARegion *region = &client->ivars->clientDMARegions[i];
        if (!region->valid || region->iova != iova) {
            continue;
        }

        if (offset + sizeof(uint64_t) > region->size) {
            return kIOReturnOverrun;
        }

        uint64_t targetIOVA = iova + offset;
        for (uint32_t chunkIdx = 0; chunkIdx < region->chunkCount; chunkIdx++) {
            VFIOUserClientDMAChunk *chunk = &region->chunks[chunkIdx];
            if (!chunk->valid || targetIOVA < chunk->iova ||
                targetIOVA + sizeof(uint64_t) > chunk->iova + chunk->size) {
                continue;
            }

            // Step 1: normal CreateMapping (kernel picks address)
            IOMemoryMap *map = nullptr;
            kern_return_t ret = chunk->memoryDescriptor->CreateMapping(
                0, 0, 0, 0, 0, &map);
            if (ret != kIOReturnSuccess || map == nullptr) {
                os_log(OS_LOG_DEFAULT,
                       "vfio-user-dext: probe CreateMapping failed iova=%#llx chunk=%#llx: %#x",
                       iova, chunk->iova, ret);
                return ret != kIOReturnSuccess ? ret : kIOReturnNoMemory;
            }

            uint64_t mappedAddr = map->GetAddress();
            uint64_t mapLength = map->GetLength();
            uint64_t chunkOffset = targetIOVA - chunk->iova;
            *outWord = *(volatile uint64_t *)(mappedAddr + chunkOffset);

            // Step 2: test kIOMemoryMapFixedAddress — remap at the same VA
            uint64_t testAddr = mappedAddr;
            map->release();
            map = nullptr;

            IOMemoryMap *fixedMap = nullptr;
            kern_return_t fixedRet = chunk->memoryDescriptor->CreateMapping(
                kIOMemoryMapFixedAddress,  // 0x1
                testAddr,                  // map at the same address we just freed
                0,                         // offset
                mapLength,                 // length
                0,                         // alignment
                &fixedMap);

            if (fixedRet == kIOReturnSuccess && fixedMap != nullptr) {
                uint64_t fixedAddr = fixedMap->GetAddress();
                uint64_t fixedWord = *(volatile uint64_t *)(fixedAddr + chunkOffset);
                vfio_user_dma_log("*** kIOMemoryMapFixedAddress TEST PASSED *** "
                       "requested=%#llx got=%#llx match=%d value_match=%d",
                       testAddr, fixedAddr, testAddr == fixedAddr, *outWord == fixedWord);
                fixedMap->release();
            } else {
                vfio_user_dma_log("*** kIOMemoryMapFixedAddress TEST FAILED *** "
                       "requested=%#llx ret=%#x",
                       testAddr, fixedRet);
            }

            return kIOReturnSuccess;
        }

        return kIOReturnNotFound;
    }

    return kIOReturnNotFound;
}

/*
 * Synthesize a PCI BAR register value from GetBARInfo() metadata.
 *
 * The raw config space BAR registers contain DART-assigned addresses whose low
 * bits do not carry reliable PCI type information.  GetBARInfo() returns the
 * original BAR metadata (type, size) from IOPCIFamily, which knows the true
 * BAR configuration.
 *
 * The address portion is left as zero — QEMU derives BAR sizes from
 * get_region_info, not from BAR probing.
 *
 * The PCIDriverKit BAR type encoding matches the PCI spec BAR register format:
 *   bit 0 = IO, bits 2:1 = memory type (10b = 64-bit), bit 3 = prefetchable
 * so the type value can be returned directly.
 */
static uint32_t
vfio_user_synthesize_bar_reg(IOPCIDevice *pciDevice, uint8_t barIndex)
{
    uint8_t memoryIndex = 0;
    uint64_t barSize = 0;
    uint8_t barType = 0;

    kern_return_t kr = pciDevice->GetBARInfo(barIndex, &memoryIndex,
                                              &barSize, &barType);
    if (kr != kIOReturnSuccess || barSize == 0) {
        return 0;
    }

    /*
     * The PCIDriverKit BAR type encoding matches the PCI spec BAR register
     * format, so return it directly.  GetBARInfo returns errors for upper
     * halves of 64-bit BARs and unused BARs, handled above.
     */
    return (uint32_t)barType;
}

static kern_return_t
vfio_user_config_read(VFIOUserPCIDriverUserClient *client,
                      uint64_t offset,
                      uint64_t width,
                      uint64_t *outValue)
{
    if (client == nullptr || client->ivars == nullptr || outValue == nullptr) {
        return kIOReturnBadArgument;
    }

    IOService *driverService = client->GetProvider();
    if (driverService == nullptr) {
        return kIOReturnNotAttached;
    }

    IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
    if (pciDevice == nullptr) {
        return kIOReturnUnsupported;
    }

    /*
     * BAR registers (0x10-0x27): synthesize proper values from GetBARInfo()
     * instead of returning DART-assigned addresses with bogus type bits.
     */
    if (width == 4 && offset >= 0x10 && offset <= 0x24 &&
        (offset & 3) == 0) {
        *outValue = vfio_user_synthesize_bar_reg(pciDevice,
                                                  (offset - 0x10) / 4);
        return kIOReturnSuccess;
    }

    switch (width) {
    case 1: {
        uint8_t val = 0xff;
        pciDevice->ConfigurationRead8(offset, &val);
        *outValue = val;
        return kIOReturnSuccess;
    }
    case 2: {
        uint16_t val = 0xffff;
        pciDevice->ConfigurationRead16(offset, &val);
        *outValue = val;
        return kIOReturnSuccess;
    }
    case 4: {
        uint32_t val = 0xffffffff;
        pciDevice->ConfigurationRead32(offset, &val);
        *outValue = val;
        return kIOReturnSuccess;
    }
    default:
        return kIOReturnBadArgument;
    }
}

static kern_return_t
vfio_user_config_write(VFIOUserPCIDriverUserClient *client,
                       uint64_t offset,
                       uint64_t width,
                       uint64_t value)
{
    if (client == nullptr || client->ivars == nullptr) {
        return kIOReturnBadArgument;
    }

    IOService *driverService = client->GetProvider();
    if (driverService == nullptr) {
        return kIOReturnNotAttached;
    }

    IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
    if (pciDevice == nullptr) {
        return kIOReturnUnsupported;
    }

    switch (width) {
    case 1:
        pciDevice->ConfigurationWrite8(offset, (uint8_t)value);
        return kIOReturnSuccess;
    case 2:
        pciDevice->ConfigurationWrite16(offset, (uint16_t)value);
        return kIOReturnSuccess;
    case 4:
        pciDevice->ConfigurationWrite32(offset, (uint32_t)value);
        return kIOReturnSuccess;
    default:
        return kIOReturnBadArgument;
    }
}

static kern_return_t
vfio_user_mmio_read(VFIOUserPCIDriverUserClient *client,
                    uint64_t memoryIndex,
                    uint64_t offset,
                    uint64_t width,
                    uint64_t *outValue)
{
    if (client == nullptr || client->ivars == nullptr || outValue == nullptr) {
        return kIOReturnBadArgument;
    }

    IOService *driverService = client->GetProvider();
    if (driverService == nullptr) {
        return kIOReturnNotAttached;
    }

    IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
    if (pciDevice == nullptr) {
        return kIOReturnUnsupported;
    }

    switch (width) {
    case 1: {
        uint8_t val = 0xff;
        pciDevice->MemoryRead8((uint8_t)memoryIndex, offset, &val);
        *outValue = val;
        return kIOReturnSuccess;
    }
    case 2: {
        uint16_t val = 0xffff;
        pciDevice->MemoryRead16((uint8_t)memoryIndex, offset, &val);
        *outValue = val;
        return kIOReturnSuccess;
    }
    case 4: {
        uint32_t val = 0xffffffff;
        pciDevice->MemoryRead32((uint8_t)memoryIndex, offset, &val);
        *outValue = val;
        return kIOReturnSuccess;
    }
    case 8: {
        uint64_t val = 0xffffffffffffffffULL;
        pciDevice->MemoryRead64((uint8_t)memoryIndex, offset, &val);
        *outValue = val;
        return kIOReturnSuccess;
    }
    default:
        return kIOReturnBadArgument;
    }
}

static kern_return_t
vfio_user_mmio_write(VFIOUserPCIDriverUserClient *client,
                     uint64_t memoryIndex,
                     uint64_t offset,
                     uint64_t width,
                     uint64_t value)
{
    if (client == nullptr || client->ivars == nullptr) {
        return kIOReturnBadArgument;
    }

    IOService *driverService = client->GetProvider();
    if (driverService == nullptr) {
        return kIOReturnNotAttached;
    }

    IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
    if (pciDevice == nullptr) {
        return kIOReturnUnsupported;
    }

    switch (width) {
    case 1:
        pciDevice->MemoryWrite8((uint8_t)memoryIndex, offset, (uint8_t)value);
        return kIOReturnSuccess;
    case 2:
        pciDevice->MemoryWrite16((uint8_t)memoryIndex, offset, (uint16_t)value);
        return kIOReturnSuccess;
    case 4:
        pciDevice->MemoryWrite32((uint8_t)memoryIndex, offset, (uint32_t)value);
        return kIOReturnSuccess;
    case 8:
        pciDevice->MemoryWrite64((uint8_t)memoryIndex, offset, value);
        return kIOReturnSuccess;
    default:
        return kIOReturnBadArgument;
    }
}

kern_return_t
IMPL(VFIOUserPCIDriver, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "vfio-user-dext: super Start failed: %#x", ret);
        return ret;
    }

    ivars = IONewZero(VFIOUserPCIDriver_IVars, 1);
    if (ivars == nullptr) {
        return kIOReturnNoMemory;
    }

    VFIOUserPCIDeviceIdentity identity;
    ret = vfio_user_read_identity(this, &identity);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "vfio-user-dext: failed to read PCI identity: %#x", ret);
        IOSafeDeleteNULL(ivars, VFIOUserPCIDriver_IVars, 1);
        return ret;
    }

    /*
     * Refuse to attach to multimedia-class functions (PCI base class 0x04).
     * On NVIDIA/AMD discrete GPUs, function 1 is an HDMI/DisplayPort audio
     * controller that this fork does not pass through (Passthrough.swift
     * filters it from auto-detect), and binding the dext to it for nothing
     * makes macOS treat that function as in-use — an extra DMA-capable
     * surface sharing the GPU's BAR aperture for no benefit. If a user ever
     * wants to pass HDA audio through, remove this guard.
     */
    if (((identity.classCode >> 16) & 0xff) == 0x04) {
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: refusing to attach to multimedia function "
               "%02x:%02x.%u vendor=%04x device=%04x class=%06x",
               (unsigned int)identity.bus,
               (unsigned int)identity.device,
               (unsigned int)identity.function,
               (unsigned int)identity.vendorID,
               (unsigned int)identity.deviceID,
               (unsigned int)identity.classCode);
        IOSafeDeleteNULL(ivars, VFIOUserPCIDriver_IVars, 1);
        return kIOReturnUnsupported;
    }

    IOPCIDevice *pciDevice = vfio_user_get_pci_device(this);
    if (pciDevice == nullptr) {
        os_log(OS_LOG_DEFAULT, "vfio-user-dext: provider is not an IOPCIDevice");
        IOSafeDeleteNULL(ivars, VFIOUserPCIDriver_IVars, 1);
        return kIOReturnUnsupported;
    }

    uint16_t command = 0xffff;
    uint16_t status = 0xffff;
    uint8_t headerType = 0xff;

    pciDevice->ConfigurationRead16(kIOPCIConfigurationOffsetCommand, &command);
    pciDevice->ConfigurationRead16(kIOPCIConfigurationOffsetStatus, &status);
    pciDevice->ConfigurationRead8(kIOPCIConfigurationOffsetHeaderType, &headerType);

    os_log(OS_LOG_DEFAULT,
           "vfio-user-dext: idle service for %02x:%02x.%u vendor=%04x device=%04x class=%06x command=%04x status=%04x header=%02x",
           (unsigned int)identity.bus,
           (unsigned int)identity.device,
           (unsigned int)identity.function,
           (unsigned int)identity.vendorID,
           (unsigned int)identity.deviceID,
           (unsigned int)identity.classCode,
           (unsigned int)command,
           (unsigned int)status,
           (unsigned int)headerType);

    for (uint8_t bar = 0; bar < 6; ++bar) {
        uint8_t memoryIndex = 0;
        uint64_t barSize = 0;
        uint8_t barType = 0;

        kern_return_t barRet = pciDevice->GetBARInfo(bar, &memoryIndex, &barSize, &barType);
        if (barRet == kIOReturnSuccess) {
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: BAR%u memoryIndex=%u size=%llu type=%{public}s",
                   (unsigned int)bar,
                   (unsigned int)memoryIndex,
                   barSize,
                   vfio_user_bar_type_string(barType));
        }
    }

    RegisterService();
    return kIOReturnSuccess;
}

kern_return_t
IMPL(VFIOUserPCIDriver, NewUserClient)
{
    if (type != 0) {
        os_log(OS_LOG_DEFAULT, "vfio-user-dext: unsupported user-client type %u", type);
        return kIOReturnUnsupported;
    }

    IOService *clientService = nullptr;
    kern_return_t ret = Create(this, "VFIOUserPCIDriverUserClientProperties", &clientService);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "vfio-user-dext: failed to create user client: %#x", ret);
        return ret;
    }

    IOUserClient *typedClient = OSDynamicCast(IOUserClient, clientService);
    if (typedClient == nullptr) {
        clientService->release();
        os_log(OS_LOG_DEFAULT, "vfio-user-dext: created service is not an IOUserClient");
        return kIOReturnUnsupported;
    }

    *userClient = typedClient;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(VFIOUserPCIDriver, Stop)
{
    for (int i = 0; i < 6; i++) {
        if (g_barDescCache[i] != nullptr) {
            g_barDescCache[i]->release();
            g_barDescCache[i] = nullptr;
        }
    }

    if (ivars != nullptr && ivars->providerClaimed) {
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: WARNING: provider still claimed in driver Stop "
               "(opener=%p refs=%u) — this should not happen",
               (void *)ivars->openerClient,
               (unsigned int)ivars->providerClaimRefs);
        ivars->providerClaimed = false;
        ivars->openerClient = nullptr;
    }
    IOSafeDeleteNULL(ivars, VFIOUserPCIDriver_IVars, 1);
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t
IMPL(VFIOUserPCIDriverUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "vfio-user-dext: user client super Start failed: %#x", ret);
        return ret;
    }

    if (OSDynamicCast(VFIOUserPCIDriver, provider) == nullptr) {
        os_log(OS_LOG_DEFAULT, "vfio-user-dext: user client provider is not VFIOUserPCIDriver");
        return kIOReturnUnsupported;
    }

    ivars = IONewZero(VFIOUserPCIDriverUserClient_IVars, 1);
    if (ivars == nullptr) {
        return kIOReturnNoMemory;
    }

    return kIOReturnSuccess;
}

static void vfio_user_release_all_interrupts(VFIOUserPCIDriverUserClient *);

kern_return_t
IMPL(VFIOUserPCIDriverUserClient, Stop)
{
    if (ivars != nullptr &&
        (ivars->activeDMARegionCount != 0 || ivars->dmaCompleteFailureCount != 0)) {
        vfio_user_dma_log(
            "stopping user client with active_regions=%llu "
            "active_chunks=%llu active_bytes=%.1f MB peak_regions=%llu "
            "peak_chunks=%llu peak_bytes=%.1f MB complete_failures=%llu",
            ivars->activeDMARegionCount,
            ivars->activeDMAChunkCount,
            vfio_user_dma_bytes_to_mb(ivars->activeDMABytes),
            ivars->peakDMARegionCount,
            ivars->peakDMAChunkCount,
            vfio_user_dma_bytes_to_mb(ivars->peakDMABytes),
            ivars->dmaCompleteFailureCount);
    }

    vfio_user_release_all_interrupts(this);
    vfio_user_release_all_client_dma_regions(this);
    vfio_user_release_dma_buffer(this);
    vfio_user_release_shared_claim(this);

    IOSafeDeleteNULL(ivars, VFIOUserPCIDriverUserClient_IVars, 1);
    return Stop(provider, SUPERDISPATCH);
}

static void
vfio_user_release_all_interrupts(VFIOUserPCIDriverUserClient *client)
{
    if (client == nullptr || client->ivars == nullptr) {
        return;
    }

    if (!client->ivars->interruptsSetUp) {
        return;
    }

    for (uint32_t i = 0; i < client->ivars->numInterrupts; i++) {
        IOInterruptDispatchSource *src = client->ivars->interruptSources[i];
        if (src != nullptr) {
            /*
             * Cancel is async — it schedules a completion block on src's
             * dispatch queue.  Release inside the completion block so the
             * source stays live until the cancel has fully drained.
             */
            src->Cancel(^{
                src->release();
            });
            client->ivars->interruptSources[i] = nullptr;
        }
    }

    if (client->ivars->irqQueue != nullptr) {
        client->ivars->irqQueue->release();
        client->ivars->irqQueue = nullptr;
    }

    client->ivars->interruptsSetUp = false;
    client->ivars->numInterrupts = 0;

    if (client->ivars->irqPending != nullptr) {
        for (int i = 0; i < VFIO_USER_IRQ_PENDING_WORDS; i++) {
            __atomic_store_n(&client->ivars->irqPending[i], 0, __ATOMIC_RELEASE);
        }
    }

    OSAction *pending = __atomic_exchange_n(
        &client->ivars->pendingInterruptNotify, nullptr, __ATOMIC_ACQ_REL);
    if (pending != nullptr) {
        pending->release();
    }

    client->ivars->irqPending = nullptr;
    client->ivars->irqEnabled = nullptr;
    OSSafeReleaseNULL(client->ivars->irqSharedBuffer);

    os_log(OS_LOG_DEFAULT, "vfio-user-dext: released all interrupt sources");
}

static uint32_t
vfio_user_get_requested_interrupt_vectors(IOPCIDevice *pciDevice,
                                          bool *outUsingMSIX)
{
    uint64_t capOffset = 0;
    uint16_t msgCtrl = 0;

    if (outUsingMSIX != nullptr) {
        *outUsingMSIX = false;
    }

    if (pciDevice == nullptr) {
        return 1;
    }

    if (pciDevice->FindPCICapability(kIOPCICapabilityIDMSIX, 0,
                                     &capOffset) == kIOReturnSuccess) {
        pciDevice->ConfigurationRead16((uint32_t)(capOffset + 2), &msgCtrl);
        if (outUsingMSIX != nullptr) {
            *outUsingMSIX = true;
        }
        return (msgCtrl & 0x07ffu) + 1u;
    }

    if (pciDevice->FindPCICapability(kIOPCICapabilityIDMSI, 0,
                                     &capOffset) == kIOReturnSuccess) {
        uint8_t mmc;

        pciDevice->ConfigurationRead16((uint32_t)(capOffset + 2), &msgCtrl);
        mmc = (msgCtrl >> 1) & 0x7;
        return 1u << mmc;
    }

    return 1;
}

static kern_return_t
vfio_user_reset_device(VFIOUserPCIDriverUserClient *client)
{
    if (client == nullptr || client->ivars == nullptr) {
        return kIOReturnBadArgument;
    }

    if (!vfio_user_service_claimed(client)) {
        return kIOReturnNotOpen;
    }

    IOService *driverService = client->GetProvider();
    if (driverService == nullptr) {
        return kIOReturnNotAttached;
    }

    IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
    if (pciDevice == nullptr) {
        return kIOReturnUnsupported;
    }

    /*
     * IOPCIDevice::Reset() handles config save/restore, link training, and
     * device-ready polling internally.  Prefer FLR; fall back to an
     * upstream-port hot reset (secondary bus reset) if the function
     * doesn't advertise FLR.
     */
    kern_return_t ret = pciDevice->Reset(kIOPCIDeviceResetTypeFunctionReset,
                                         kIOPCIDeviceResetOptionNone);
    if (ret == kIOReturnSuccess) {
        return ret;
    }

    return pciDevice->Reset(kIOPCIDeviceResetTypeHotReset,
                            kIOPCIDeviceResetOptionNone);
}

static kern_return_t
vfio_user_setup_interrupts(VFIOUserPCIDriverUserClient *client)
{
    if (client == nullptr || client->ivars == nullptr) {
        return kIOReturnBadArgument;
    }

    if (!vfio_user_service_claimed(client)) {
        return kIOReturnNotOpen;
    }

    if (client->ivars->interruptsSetUp) {
        return kIOReturnStillOpen;
    }

    IOService *driverService = client->GetProvider();
    if (driverService == nullptr) {
        return kIOReturnNotAttached;
    }

    IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
    if (pciDevice == nullptr) {
        return kIOReturnUnsupported;
    }

    IODispatchQueue *irqDispatchQueue = nullptr;
    kern_return_t ret = IODispatchQueue::Create("VFIOUserIRQQueue", 0, 0,
                                                 &irqDispatchQueue);
    if (ret != kIOReturnSuccess || irqDispatchQueue == nullptr) {
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: failed to create IRQ dispatch queue: %#x", ret);
        return ret != kIOReturnSuccess ? ret : kIOReturnNoMemory;
    }

    client->ivars->irqQueue = irqDispatchQueue;

    /* Allocate the shared IRQ state page */
    IOBufferMemoryDescriptor *irqBuf = nullptr;
    ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionOutIn,
                                           16384, 16384, &irqBuf);
    if (ret != kIOReturnSuccess || irqBuf == nullptr) {
        irqDispatchQueue->release();
        client->ivars->irqQueue = nullptr;
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: failed to create IRQ shared buffer: %#x", ret);
        return ret != kIOReturnSuccess ? ret : kIOReturnNoMemory;
    }

    IOAddressSegment irqRange = {};
    ret = irqBuf->GetAddressRange(&irqRange);
    if (ret != kIOReturnSuccess || irqRange.address == 0) {
        irqBuf->release();
        irqDispatchQueue->release();
        client->ivars->irqQueue = nullptr;
        return kIOReturnNoMemory;
    }

    auto *shared = reinterpret_cast<volatile uint64_t *>(irqRange.address);
    client->ivars->irqSharedBuffer = irqBuf;
    client->ivars->irqPending = shared;                          /* offset 0x00 */
    client->ivars->irqEnabled = shared + VFIO_USER_IRQ_PENDING_WORDS; /* offset 0x20 */

    for (int i = 0; i < VFIO_USER_IRQ_PENDING_WORDS; i++) {
        __atomic_store_n(&client->ivars->irqPending[i], 0, __ATOMIC_RELEASE);
        __atomic_store_n(&client->ivars->irqEnabled[i], ~0ULL, __ATOMIC_RELEASE);
    }
    client->ivars->pendingInterruptNotify = nullptr;

    bool usingMSIX = false;
    uint32_t requested = vfio_user_get_requested_interrupt_vectors(pciDevice,
                                                                   &usingMSIX);
    if (requested == 0 || requested > VFIO_USER_MAX_IRQ_VECTORS) {
        requested = VFIO_USER_MAX_IRQ_VECTORS;
    }

    ret = pciDevice->ConfigureInterrupts(usingMSIX ?
                                         kIOInterruptTypePCIMessagedX :
                                         kIOInterruptTypePCIMessaged,
                                         1, requested, 0);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: ConfigureInterrupts(%{public}s, requested=%u) failed: %#x",
               usingMSIX ? "MSI-X" : "MSI",
               (unsigned int)requested, ret);

        if (usingMSIX) {
            usingMSIX = false;
            requested = 1;
            ret = pciDevice->ConfigureInterrupts(kIOInterruptTypePCIMessaged,
                                                 1, requested, 0);
            if (ret != kIOReturnSuccess) {
                os_log(OS_LOG_DEFAULT,
                       "vfio-user-dext: ConfigureInterrupts(MSI fallback) failed: %#x",
                       ret);
            }
        }
    } else {
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: ConfigureInterrupts(%{public}s) requested=%u",
               usingMSIX ? "MSI-X" : "MSI",
               (unsigned int)requested);
    }

    uint32_t registered = 0;

    for (uint32_t i = 0; i < requested; i++) {
        IOInterruptDispatchSource *source = nullptr;

        ret = IOInterruptDispatchSource::Create(pciDevice, i,
                                                 irqDispatchQueue, &source);
        if (ret != kIOReturnSuccess || source == nullptr) {
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: IOInterruptDispatchSource::Create failed for vector %u/%u: %#x",
                   (unsigned int)i, (unsigned int)requested, ret);
            break;
        }

        OSAction *action = nullptr;
        ret = client->CreateActionInterruptOccurred(sizeof(uint32_t),
                                                     &action);
        if (ret != kIOReturnSuccess || action == nullptr) {
            source->release();
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: CreateAction failed for vector %u: %#x",
                   i, ret);
            break;
        }

        uint32_t *vectorRef = (uint32_t *)action->GetReference();
        if (vectorRef != nullptr) {
            *vectorRef = i;
        }

        ret = source->SetHandler(action);
        if (ret != kIOReturnSuccess) {
            action->release();
            source->release();
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: SetHandler failed for vector %u: %#x",
                   i, ret);
            break;
        }

        ret = source->SetEnable(true);
        if (ret != kIOReturnSuccess) {
            action->release();
            source->release();
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: SetEnable failed for vector %u: %#x",
                   i, ret);
            break;
        }

        client->ivars->interruptSources[i] = source;
        registered++;
    }

    client->ivars->numInterrupts = registered;
    client->ivars->interruptsSetUp = (registered > 0);

    os_log(OS_LOG_DEFAULT,
           "vfio-user-dext: registered %u/%u interrupt vectors (%{public}s)",
           (unsigned int)registered, (unsigned int)requested,
           usingMSIX ? "MSI-X" : "MSI");

    return registered > 0 ? kIOReturnSuccess : kIOReturnNotFound;
}

kern_return_t
VFIOUserPCIDriverUserClient::ExternalMethod(uint64_t selector,
                                            IOUserClientMethodArguments *arguments,
                                            const IOUserClientMethodDispatch *dispatch,
                                            OSObject *target,
                                            void *reference)
{
    (void)dispatch;
    (void)target;
    (void)reference;

    if (arguments == nullptr) {
        return kIOReturnBadArgument;
    }

    IOService *driverService = GetProvider();
    if (driverService == nullptr) {
        return kIOReturnNotAttached;
    }

    VFIOUserPCIDeviceIdentity identity;
    kern_return_t ret = vfio_user_read_identity(driverService, &identity);
    if (ret != kIOReturnSuccess) {
        return ret;
    }

    switch (selector) {
    case kVFIOUserPCIDriverUserClientMethodGetIdentity:
        if (arguments->scalarOutput == nullptr || arguments->scalarOutputCount < 6) {
            return kIOReturnBadArgument;
        }

        arguments->scalarOutput[0] = identity.bus;
        arguments->scalarOutput[1] = identity.device;
        arguments->scalarOutput[2] = identity.function;
        arguments->scalarOutput[3] = identity.vendorID;
        arguments->scalarOutput[4] = identity.deviceID;
        arguments->scalarOutput[5] = identity.classCode;
        arguments->scalarOutputCount = 6;
        return kIOReturnSuccess;

    case kVFIOUserPCIDriverUserClientMethodClaim: {
        return vfio_user_retain_shared_claim(this, driverService, &identity);
    }

    case kVFIOUserPCIDriverUserClientMethodTerminate:
        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: terminating driver for %02x:%02x.%u (not selected by host app)",
               (unsigned int)identity.bus,
               (unsigned int)identity.device,
               (unsigned int)identity.function);
        driverService->Terminate(0);
        return kIOReturnSuccess;

    case kVFIOUserPCIDriverUserClientMethodAllocateDMABuffer: {
        if (arguments->scalarInput == nullptr || arguments->scalarInputCount < 2) {
            return kIOReturnBadArgument;
        }
        if (arguments->scalarOutput == nullptr || arguments->scalarOutputCount < 6) {
            return kIOReturnBadArgument;
        }

        ret = vfio_user_allocate_dma_buffer(this,
                                            arguments->scalarInput[0],
                                            arguments->scalarInput[1]);
        if (ret != kIOReturnSuccess) {
            return ret;
        }

        arguments->scalarOutput[0] = ivars->dmaBufferSize;
        arguments->scalarOutput[1] = ivars->dmaFlags;
        arguments->scalarOutput[2] = ivars->dmaSegmentsCount;
        arguments->scalarOutput[3] = ivars->dmaSegmentsCount > 0 ? ivars->dmaSegments[0].address : 0;
        arguments->scalarOutput[4] = ivars->dmaSegmentsCount > 0 ? ivars->dmaSegments[0].length : 0;
        arguments->scalarOutput[5] = identity.classCode;
        arguments->scalarOutputCount = 6;
        return kIOReturnSuccess;
    }

    case kVFIOUserPCIDriverUserClientMethodFreeDMABuffer:
        vfio_user_release_dma_buffer(this);
        return kIOReturnSuccess;

    case kVFIOUserPCIDriverUserClientMethodRegisterDMARegion: {
        if (arguments->scalarInput == nullptr || arguments->scalarInputCount < 3) {
            return kIOReturnBadArgument;
        }
        if (arguments->scalarOutput == nullptr || arguments->scalarOutputCount < 3) {
            return kIOReturnBadArgument;
        }

        IOAddressSegment busSegments[8];
        uint32_t busSegmentsCount = 8;

        ret = vfio_user_register_client_dma_region(this,
                                                   arguments->scalarInput[0],
                                                   arguments->scalarInput[1],
                                                   arguments->scalarInput[2],
                                                   &busSegmentsCount,
                                                   busSegments,
                                                   8);
        if (ret != kIOReturnSuccess) {
            return ret;
        }

        arguments->scalarOutput[0] = busSegmentsCount;
        arguments->scalarOutput[1] = busSegmentsCount > 0 ? busSegments[0].address : 0;
        arguments->scalarOutput[2] = busSegmentsCount > 0 ? busSegments[0].length : 0;
        arguments->scalarOutputCount = 3;
        return kIOReturnSuccess;
    }

    case kVFIOUserPCIDriverUserClientMethodUnregisterDMARegion: {
        if (arguments->scalarInput == nullptr || arguments->scalarInputCount < 1) {
            return kIOReturnBadArgument;
        }

        return vfio_user_unregister_client_dma_region(this,
                                                      arguments->scalarInput[0]);
    }

    case kVFIOUserPCIDriverUserClientMethodProbeDMARegion: {
        if (arguments->scalarInput == nullptr || arguments->scalarInputCount < 2) {
            return kIOReturnBadArgument;
        }
        if (arguments->scalarOutput == nullptr || arguments->scalarOutputCount < 1) {
            return kIOReturnBadArgument;
        }

        uint64_t probeWord = 0;
        ret = vfio_user_probe_client_dma_region(this,
                                                arguments->scalarInput[0],
                                                arguments->scalarInput[1],
                                                &probeWord);
        if (ret != kIOReturnSuccess) {
            return ret;
        }

        arguments->scalarOutput[0] = probeWord;
        arguments->scalarOutputCount = 1;
        return kIOReturnSuccess;
    }

    case kVFIOUserPCIDriverUserClientMethodConfigRead: {
        if (arguments->scalarInput == nullptr || arguments->scalarInputCount < 2) {
            return kIOReturnBadArgument;
        }
        if (arguments->scalarOutput == nullptr || arguments->scalarOutputCount < 1) {
            return kIOReturnBadArgument;
        }

        uint64_t configValue = 0;
        ret = vfio_user_config_read(this,
                                    arguments->scalarInput[0],
                                    arguments->scalarInput[1],
                                    &configValue);
        if (ret != kIOReturnSuccess) {
            return ret;
        }

        arguments->scalarOutput[0] = configValue;
        arguments->scalarOutputCount = 1;
        return kIOReturnSuccess;
    }

    case kVFIOUserPCIDriverUserClientMethodConfigWrite: {
        if (arguments->scalarInput == nullptr || arguments->scalarInputCount < 3) {
            return kIOReturnBadArgument;
        }

        return vfio_user_config_write(this,
                                      arguments->scalarInput[0],
                                      arguments->scalarInput[1],
                                      arguments->scalarInput[2]);
    }

    case kVFIOUserPCIDriverUserClientMethodGetBARInfo: {
        if (arguments->scalarInput == nullptr || arguments->scalarInputCount < 1) {
            return kIOReturnBadArgument;
        }
        if (arguments->scalarOutput == nullptr || arguments->scalarOutputCount < 3) {
            return kIOReturnBadArgument;
        }

        IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
        if (pciDevice == nullptr) {
            return kIOReturnUnsupported;
        }

        uint8_t barIndex = (uint8_t)arguments->scalarInput[0];
        uint8_t memoryIndex = 0;
        uint64_t barSize = 0;
        uint8_t barType = 0;
        ret = pciDevice->GetBARInfo(barIndex, &memoryIndex, &barSize,
                                     &barType);
        if (ret != kIOReturnSuccess) {
            return ret;
        }

        arguments->scalarOutput[0] = memoryIndex;
        arguments->scalarOutput[1] = barSize;
        arguments->scalarOutput[2] = barType;
        arguments->scalarOutputCount = 3;
        return kIOReturnSuccess;
    }

    case kVFIOUserPCIDriverUserClientMethodMMIORead: {
        if (arguments->scalarInput == nullptr || arguments->scalarInputCount < 3) {
            return kIOReturnBadArgument;
        }
        if (arguments->scalarOutput == nullptr || arguments->scalarOutputCount < 1) {
            return kIOReturnBadArgument;
        }

        uint64_t mmioValue = 0;
        ret = vfio_user_mmio_read(this,
                                  arguments->scalarInput[0],
                                  arguments->scalarInput[1],
                                  arguments->scalarInput[2],
                                  &mmioValue);
        if (ret != kIOReturnSuccess) {
            return ret;
        }

        arguments->scalarOutput[0] = mmioValue;
        arguments->scalarOutputCount = 1;
        return kIOReturnSuccess;
    }

    case kVFIOUserPCIDriverUserClientMethodMMIOWrite: {
        if (arguments->scalarInput == nullptr || arguments->scalarInputCount < 4) {
            return kIOReturnBadArgument;
        }

        return vfio_user_mmio_write(this,
                                    arguments->scalarInput[0],
                                    arguments->scalarInput[1],
                                    arguments->scalarInput[2],
                                    arguments->scalarInput[3]);
    }

    case kVFIOUserPCIDriverUserClientMethodSetupInterrupts: {
        if (arguments->scalarOutput == nullptr || arguments->scalarOutputCount < 1) {
            return kIOReturnBadArgument;
        }

        ret = vfio_user_setup_interrupts(this);
        if (ret != kIOReturnSuccess) {
            return ret;
        }

        arguments->scalarOutput[0] = ivars->numInterrupts;
        arguments->scalarOutputCount = 1;
        return kIOReturnSuccess;
    }

    case kVFIOUserPCIDriverUserClientMethodCheckInterrupt: {
        if (arguments->scalarOutput == nullptr ||
            arguments->scalarOutputCount < VFIO_USER_IRQ_PENDING_WORDS) {
            return kIOReturnBadArgument;
        }

        if (ivars == nullptr || !ivars->interruptsSetUp) {
            return kIOReturnNotReady;
        }

        for (int i = 0; i < VFIO_USER_IRQ_PENDING_WORDS; i++) {
            arguments->scalarOutput[i] =
                __atomic_exchange_n(&ivars->irqPending[i], 0,
                                    __ATOMIC_ACQ_REL);
        }
        arguments->scalarOutputCount = VFIO_USER_IRQ_PENDING_WORDS;
        return kIOReturnSuccess;
    }

    case kVFIOUserPCIDriverUserClientMethodWaitInterrupt: {
        if (arguments->completion == nullptr) {
            return kIOReturnBadArgument;
        }

        if (ivars == nullptr || !ivars->interruptsSetUp) {
            return kIOReturnNotReady;
        }

        arguments->completion->retain();
        OSAction *old = __atomic_exchange_n(
            &ivars->pendingInterruptNotify,
            arguments->completion, __ATOMIC_ACQ_REL);
        if (old != nullptr) {
            old->release();
        }

        /*
         * If any bits are already pending, complete immediately so the
         * client doesn't miss interrupts that arrived before arming.
         */
        bool pending = false;
        for (int i = 0; i < VFIO_USER_IRQ_PENDING_WORDS; i++) {
            if (__atomic_load_n(&ivars->irqPending[i], __ATOMIC_ACQUIRE)) {
                pending = true;
                break;
            }
        }
        if (pending) {
            OSAction *act = __atomic_exchange_n(
                &ivars->pendingInterruptNotify, nullptr, __ATOMIC_ACQ_REL);
            if (act != nullptr) {
                AsyncCompletion(act, kIOReturnSuccess, nullptr, 0);
                act->release();
            }
        }
        return kIOReturnSuccess;
    }

    case kVFIOUserPCIDriverUserClientMethodResetDevice:
        return vfio_user_reset_device(this);

    case kVFIOUserPCIDriverUserClientMethodSetIRQMask: {
        if (arguments->scalarInput == nullptr ||
            arguments->scalarInputCount < VFIO_USER_IRQ_PENDING_WORDS) {
            return kIOReturnBadArgument;
        }

        if (ivars == nullptr || !ivars->interruptsSetUp) {
            return kIOReturnNotReady;
        }

        for (int i = 0; i < VFIO_USER_IRQ_PENDING_WORDS; i++) {
            __atomic_store_n(&ivars->irqEnabled[i],
                             arguments->scalarInput[i], __ATOMIC_RELEASE);
        }
        return kIOReturnSuccess;
    }

    default:
        return kIOReturnUnsupported;
    }
}

void
IMPL(VFIOUserPCIDriverUserClient, InterruptOccurred)
{
    if (ivars == nullptr || !ivars->interruptsSetUp) {
        return;
    }

    uint32_t vector = UINT32_MAX;

    uint32_t *vectorRef = (uint32_t *)action->GetReference();
    if (vectorRef != nullptr) {
        vector = *vectorRef;
    }

    if (vector >= ivars->numInterrupts) {
        return;
    }

    /* Only signal if this vector is enabled by the client */
    uint32_t word = vector / 64;
    uint64_t bit = 1ULL << (vector % 64);

    if (!(__atomic_load_n(&ivars->irqEnabled[word], __ATOMIC_ACQUIRE) & bit)) {
        return;
    }

    /* Set the pending bit for this vector */
    __atomic_fetch_or(&ivars->irqPending[word], bit, __ATOMIC_RELEASE);

    /* Wake the client if it has an outstanding async wait */
    OSAction *notify = __atomic_exchange_n(
        &ivars->pendingInterruptNotify, nullptr, __ATOMIC_ACQ_REL);
    if (notify != nullptr) {
        AsyncCompletion(notify, kIOReturnSuccess, nullptr, 0);
        notify->release();
    }
}

void
IMPL(VFIOUserPCIDriverUserClient, AsyncCompletion)
{
}

kern_return_t
IMPL(VFIOUserPCIDriverUserClient, CopyClientMemoryForType)
{
    if (memory == nullptr || options == nullptr) {
        return kIOReturnBadArgument;
    }

    if (type == kVFIOUserPCIDriverUserClientMemoryTypeIRQState) {
        if (ivars == nullptr || ivars->irqSharedBuffer == nullptr) {
            return kIOReturnNotReady;
        }
        ivars->irqSharedBuffer->retain();
        *options = 0;
        *memory = ivars->irqSharedBuffer;
        return kIOReturnSuccess;
    }

    if (type == kVFIOUserPCIDriverUserClientMemoryTypeDMABuffer) {
        if (ivars == nullptr || ivars->dmaBuffer == nullptr) {
            return kIOReturnNotReady;
        }
        ivars->dmaBuffer->retain();
        *options = 0;
        *memory = ivars->dmaBuffer;
        return kIOReturnSuccess;
    }

    if (type >= kVFIOUserPCIDriverUserClientMemoryTypeBAR0 &&
        type <= kVFIOUserPCIDriverUserClientMemoryTypeBAR5) {
        if (ivars == nullptr) {
            return kIOReturnBadArgument;
        }

        uint8_t barIndex =
            (uint8_t)(type - kVFIOUserPCIDriverUserClientMemoryTypeBAR0);

        /*
         * Secondary (unclaimed) clients use the cached descriptor that was
         * populated by the primary client's first mapping request.
         */
        if (!ivars->claimed && barIndex < 6 &&
            g_barDescCache[barIndex] != nullptr) {
            g_barDescCache[barIndex]->retain();
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: providing cached BAR%u descriptor for shared user client",
                   (unsigned int)barIndex);
            *options = 0;
            *memory = g_barDescCache[barIndex];
            return kIOReturnSuccess;
        }

        IOService *driverService = GetProvider();
        if (driverService == nullptr) {
            return kIOReturnNotAttached;
        }

        IOPCIDevice *pciDevice = vfio_user_get_pci_device(driverService);
        if (pciDevice == nullptr) {
            return kIOReturnUnsupported;
        }

        uint8_t memoryIndex = 0;
        uint64_t barSize = 0;
        uint8_t barType = 0;
        kern_return_t ret;

        ret = pciDevice->GetBARInfo(barIndex,
                                    &memoryIndex, &barSize, &barType);
        if (ret != kIOReturnSuccess) {
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: GetBARInfo failed for BAR%u: %#x",
                   (unsigned int)barIndex, ret);
            return ret;
        }

        IOMemoryDescriptor *barMemory = nullptr;
        VFIOUserPCIDriver *driver = OSDynamicCast(VFIOUserPCIDriver, driverService);
        IOService *opener = (IOService *)this;
        if (driver != nullptr && driver->ivars != nullptr &&
            driver->ivars->openerClient != nullptr) {
            opener = (IOService *)driver->ivars->openerClient;
        }
        ret = pciDevice->_CopyDeviceMemoryWithIndex(memoryIndex,
                                                    &barMemory, opener);
        if (ret != kIOReturnSuccess || barMemory == nullptr) {
            os_log(OS_LOG_DEFAULT,
                   "vfio-user-dext: _CopyDeviceMemoryWithIndex failed BAR%u idx=%u: %#x (opener=%s)",
                   (unsigned int)barIndex, (unsigned int)memoryIndex, ret,
                   (opener == (IOService *)this) ? "self" : "primary-client");
            return ret != kIOReturnSuccess ? ret : kIOReturnNoMemory;
        }

        if (barIndex < 6 && g_barDescCache[barIndex] == nullptr) {
            barMemory->retain();
            g_barDescCache[barIndex] = barMemory;
        }

        os_log(OS_LOG_DEFAULT,
               "vfio-user-dext: providing BAR%u memory descriptor size=%llu for %s user client mapping",
               (unsigned int)barIndex, barSize,
               ivars->claimed ? "claimed" : "shared");

        *options = 0;
        *memory = barMemory;
        return kIOReturnSuccess;
    }

    return kIOReturnUnsupported;
}
