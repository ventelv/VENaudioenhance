#ifndef VEN_INTERNAL_H
#define VEN_INTERNAL_H

#include "ven_dsp.h"

void ven_limiter_reset(ven_limiter *l);
void ven_limiter_configure(ven_limiter *l, float ceiling_dbtp, float release_ms, int enabled);
// Lowest gain applied since the last call, for metering.
float ven_limiter_take_min_gain(ven_limiter *l);

#endif
