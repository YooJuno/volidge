#ifndef VOL_ATOMICS_H
#define VOL_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

typedef struct VolAtomicUInt32 VolAtomicUInt32;
typedef struct VolAtomicUInt64 VolAtomicUInt64;

VolAtomicUInt32 *VolAtomicUInt32Create(uint32_t initialValue);
void VolAtomicUInt32Destroy(VolAtomicUInt32 *atomicValue);
uint32_t VolAtomicUInt32LoadAcquire(const VolAtomicUInt32 *atomicValue);
uint32_t VolAtomicUInt32LoadRelaxed(const VolAtomicUInt32 *atomicValue);
void VolAtomicUInt32StoreRelease(VolAtomicUInt32 *atomicValue, uint32_t newValue);
void VolAtomicUInt32StoreRelaxed(VolAtomicUInt32 *atomicValue, uint32_t newValue);

VolAtomicUInt64 *VolAtomicUInt64Create(uint64_t initialValue);
void VolAtomicUInt64Destroy(VolAtomicUInt64 *atomicValue);
uint64_t VolAtomicUInt64LoadAcquire(const VolAtomicUInt64 *atomicValue);
uint64_t VolAtomicUInt64LoadRelaxed(const VolAtomicUInt64 *atomicValue);
void VolAtomicUInt64StoreRelease(VolAtomicUInt64 *atomicValue, uint64_t newValue);
void VolAtomicUInt64StoreRelaxed(VolAtomicUInt64 *atomicValue, uint64_t newValue);
uint64_t VolAtomicUInt64FetchAddRelaxed(VolAtomicUInt64 *atomicValue, uint64_t amount);
bool VolAtomicUInt64CompareExchangeRelaxed(
    VolAtomicUInt64 *atomicValue,
    uint64_t *expectedValue,
    uint64_t desiredValue
);

#endif
