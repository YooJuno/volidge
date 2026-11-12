#include "VolAtomics.h"

#include <stdatomic.h>
#include <stdlib.h>

struct VolAtomicUInt32 {
    _Atomic uint32_t value;
};

struct VolAtomicUInt64 {
    _Atomic uint64_t value;
};

VolAtomicUInt32 *VolAtomicUInt32Create(uint32_t initialValue) {
    VolAtomicUInt32 *atomicValue = malloc(sizeof(VolAtomicUInt32));
    if (atomicValue != NULL) {
        atomic_init(&atomicValue->value, initialValue);
    }
    return atomicValue;
}

void VolAtomicUInt32Destroy(VolAtomicUInt32 *atomicValue) {
    free(atomicValue);
}

uint32_t VolAtomicUInt32LoadAcquire(const VolAtomicUInt32 *atomicValue) {
    return atomic_load_explicit(&atomicValue->value, memory_order_acquire);
}

uint32_t VolAtomicUInt32LoadRelaxed(const VolAtomicUInt32 *atomicValue) {
    return atomic_load_explicit(&atomicValue->value, memory_order_relaxed);
}

void VolAtomicUInt32StoreRelease(VolAtomicUInt32 *atomicValue, uint32_t newValue) {
    atomic_store_explicit(&atomicValue->value, newValue, memory_order_release);
}

void VolAtomicUInt32StoreRelaxed(VolAtomicUInt32 *atomicValue, uint32_t newValue) {
    atomic_store_explicit(&atomicValue->value, newValue, memory_order_relaxed);
}

VolAtomicUInt64 *VolAtomicUInt64Create(uint64_t initialValue) {
    VolAtomicUInt64 *atomicValue = malloc(sizeof(VolAtomicUInt64));
    if (atomicValue != NULL) {
        atomic_init(&atomicValue->value, initialValue);
    }
    return atomicValue;
}

void VolAtomicUInt64Destroy(VolAtomicUInt64 *atomicValue) {
    free(atomicValue);
}

uint64_t VolAtomicUInt64LoadAcquire(const VolAtomicUInt64 *atomicValue) {
    return atomic_load_explicit(&atomicValue->value, memory_order_acquire);
}

uint64_t VolAtomicUInt64LoadRelaxed(const VolAtomicUInt64 *atomicValue) {
    return atomic_load_explicit(&atomicValue->value, memory_order_relaxed);
}

void VolAtomicUInt64StoreRelease(VolAtomicUInt64 *atomicValue, uint64_t newValue) {
    atomic_store_explicit(&atomicValue->value, newValue, memory_order_release);
}

void VolAtomicUInt64StoreRelaxed(VolAtomicUInt64 *atomicValue, uint64_t newValue) {
    atomic_store_explicit(&atomicValue->value, newValue, memory_order_relaxed);
}

uint64_t VolAtomicUInt64FetchAddRelaxed(VolAtomicUInt64 *atomicValue, uint64_t amount) {
    return atomic_fetch_add_explicit(&atomicValue->value, amount, memory_order_relaxed);
}

bool VolAtomicUInt64CompareExchangeRelaxed(
    VolAtomicUInt64 *atomicValue,
    uint64_t *expectedValue,
    uint64_t desiredValue
) {
    return atomic_compare_exchange_weak_explicit(
        &atomicValue->value,
        expectedValue,
        desiredValue,
        memory_order_relaxed,
        memory_order_relaxed
    );
}
