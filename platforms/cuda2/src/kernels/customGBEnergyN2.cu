#define STORE_DERIVATIVE_1(INDEX) atomicAdd(&derivBuffers[offset+(INDEX-1)*PADDED_NUM_ATOMS], static_cast<unsigned long long>((long long) (deriv##INDEX##_1*0xFFFFFFFF)));
#define STORE_DERIVATIVE_2(INDEX) atomicAdd(&derivBuffers[offset+(INDEX-1)*PADDED_NUM_ATOMS], static_cast<unsigned long long>((long long) (localData[threadIdx.x].deriv##INDEX*0xFFFFFFFF)));
#define TILE_SIZE 32

DEFINE_ACCUM

typedef struct {
    real4 posq;
    accum3 force;
    ATOM_PARAMETER_DATA
#ifdef NEED_PADDING
    float padding;
#endif
} AtomData;

/**
 * Compute a force based on pair interactions.
 */
extern "C" __global__ void computeN2Energy(unsigned long long* __restrict__ forceBuffers, real* __restrict__ energyBuffer,
        const real4* __restrict__ posq, const unsigned int* __restrict__ exclusions, const unsigned int* __restrict__ exclusionIndices,
        const unsigned int* __restrict__ exclusionRowIndices,
#ifdef USE_CUTOFF
        const ushort2* __restrict__ tiles, const unsigned int* __restrict__ interactionCount, real4 periodicBoxSize, real4 invPeriodicBoxSize, unsigned int maxTiles, const unsigned int* __restrict__ interactionFlags
#else
        unsigned int numTiles
#endif
        PARAMETER_ARGUMENTS) {
    unsigned int totalWarps = (blockDim.x*gridDim.x)/TILE_SIZE;
    unsigned int warp = (blockIdx.x*blockDim.x+threadIdx.x)/TILE_SIZE;
#ifdef USE_CUTOFF
    unsigned int numTiles = interactionCount[0];
    unsigned int pos = warp*(numTiles > maxTiles ? NUM_BLOCKS*(NUM_BLOCKS+1)/2 : numTiles)/totalWarps;
    unsigned int end = (warp+1)*(numTiles > maxTiles ? NUM_BLOCKS*(NUM_BLOCKS+1)/2 : numTiles)/totalWarps;
#else
    unsigned int pos = warp*numTiles/totalWarps;
    unsigned int end = (warp+1)*numTiles/totalWarps;
#endif
    real energy = 0;
    unsigned int lasty = 0xFFFFFFFF;
    __shared__ AtomData localData[THREAD_BLOCK_SIZE];
    __shared__ unsigned int exclusionRange[2*WARPS_PER_GROUP];
    __shared__ int exclusionIndex[WARPS_PER_GROUP];
    
    do {
        // Extract the coordinates of this tile
        const unsigned int tgx = threadIdx.x & (TILE_SIZE-1);
        const unsigned int tbx = threadIdx.x - tgx;
        const unsigned int localGroupIndex = threadIdx.x/TILE_SIZE;
        unsigned int x, y;
        accum3 force = make_accum3(0);
        DECLARE_ATOM1_DERIVATIVES
        if (pos < end) {
#ifdef USE_CUTOFF
            if (numTiles <= maxTiles) {
                ushort2 tileIndices = tiles[pos];
                x = tileIndices.x;
                y = tileIndices.y;
            }
            else
#endif
            {
                y = (unsigned int) floor(NUM_BLOCKS+0.5f-SQRT((NUM_BLOCKS+0.5f)*(NUM_BLOCKS+0.5f)-2*pos));
                x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
                if (x < y || x >= NUM_BLOCKS) { // Occasionally happens due to roundoff error.
                    y += (x < y ? -1 : 1);
                    x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
                }
            }
            unsigned int atom1 = x*TILE_SIZE + tgx;
            real4 posq1 = posq[atom1];
            LOAD_ATOM1_PARAMETERS

            // Locate the exclusion data for this tile.

#ifdef USE_EXCLUSIONS
            if (tgx < 2)
                exclusionRange[2*localGroupIndex+tgx] = exclusionRowIndices[x+tgx];
            if (tgx == 0)
                exclusionIndex[localGroupIndex] = -1;
            for (unsigned int i = exclusionRange[2*localGroupIndex]+tgx; i < exclusionRange[2*localGroupIndex+1]; i += TILE_SIZE)
                if (exclusionIndices[i] == y)
                    exclusionIndex[localGroupIndex] = i*TILE_SIZE;
            bool hasExclusions = (exclusionIndex[localGroupIndex] > -1);
#else
            bool hasExclusions = false;
#endif
            if (pos >= end)
                ; // This warp is done.
            else if (x == y) {
                // This tile is on the diagonal.

                const unsigned int localAtomIndex = threadIdx.x;
                localData[localAtomIndex].posq = posq1;
                LOAD_LOCAL_PARAMETERS_FROM_1
#ifdef USE_EXCLUSIONS
                unsigned int excl = exclusions[exclusionIndex[localGroupIndex]+tgx];
#endif
                for (unsigned int j = 0; j < TILE_SIZE; j++) {
#ifdef USE_EXCLUSIONS
                    bool isExcluded = !(excl & 0x1);
#endif
                    int atom2 = tbx+j;
                    real4 posq2 = localData[atom2].posq;
                    real3 delta = make_real3(posq2.x-posq1.x, posq2.y-posq1.y, posq2.z-posq1.z);
#ifdef USE_PERIODIC
                    delta.x -= floor(delta.x*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x;
                    delta.y -= floor(delta.y*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y;
                    delta.z -= floor(delta.z*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;
#endif
                    real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
#ifdef USE_CUTOFF
                    if (r2 < CUTOFF_SQUARED) {
#endif
                    real invR = RSQRT(r2);
                    real r = RECIP(invR);
                    LOAD_ATOM2_PARAMETERS
                    atom2 = y*TILE_SIZE+j;
                    real dEdR = 0;
                    real tempEnergy = 0;
                    if (atom1 < NUM_ATOMS && atom2 < NUM_ATOMS && atom1 != atom2) {
                        COMPUTE_INTERACTION
                        dEdR /= -r;
                    }
                    energy += 0.5f*tempEnergy;
                    delta *= dEdR;
                    force.x -= delta.x;
                    force.y -= delta.y;
                    force.z -= delta.z;
#ifdef USE_CUTOFF
                    }
#endif
#ifdef USE_EXCLUSIONS
                    excl >>= 1;
#endif
                }
            }
            else {
                // This is an off-diagonal tile.

                const unsigned int localAtomIndex = threadIdx.x;
                if (lasty != y) {
                    unsigned int j = y*TILE_SIZE + tgx;
                    localData[localAtomIndex].posq = posq[j];
                    LOAD_LOCAL_PARAMETERS_FROM_GLOBAL
                }
                localData[localAtomIndex].force = make_accum3(0);
                CLEAR_LOCAL_DERIVATIVES
#ifdef USE_CUTOFF
                unsigned int flags = (numTiles <= maxTiles ? interactionFlags[pos] : 0xFFFFFFFF);
                if (!hasExclusions && flags == 0) {
                    // No interactions in this tile.
                }
                else
#endif
                {
                    // Compute the full set of interactions in this tile.

#ifdef USE_EXCLUSIONS
                    unsigned int excl = (hasExclusions ? exclusions[exclusionIndex[localGroupIndex]+tgx] : 0xFFFFFFFF);
                    excl = (excl >> tgx) | (excl << (TILE_SIZE - tgx));
#endif
                    unsigned int tj = tgx;
                    for (unsigned int j = 0; j < TILE_SIZE; j++) {
#ifdef USE_EXCLUSIONS
                        bool isExcluded = !(excl & 0x1);
#endif
                        int atom2 = tbx+tj;
                        real4 posq2 = localData[atom2].posq;
                        real3 delta = make_real3(posq2.x-posq1.x, posq2.y-posq1.y, posq2.z-posq1.z);
#ifdef USE_PERIODIC
                        delta.x -= floor(delta.x*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x;
                        delta.y -= floor(delta.y*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y;
                        delta.z -= floor(delta.z*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;
#endif
                        real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
#ifdef USE_CUTOFF
                        if (r2 < CUTOFF_SQUARED) {
#endif
                        real invR = RSQRT(r2);
                        real r = RECIP(invR);
                        LOAD_ATOM2_PARAMETERS
                        atom2 = y*TILE_SIZE+tj;
                        real dEdR = 0;
                        real tempEnergy = 0;
                        if (atom1 < NUM_ATOMS && atom2 < NUM_ATOMS) {
                            COMPUTE_INTERACTION
                            dEdR /= -r;
                        }
                        energy += tempEnergy;
                        delta *= dEdR;
                        force.x -= delta.x;
                        force.y -= delta.y;
                        force.z -= delta.z;
                        atom2 = tbx+tj;
                        localData[atom2].force.x += delta.x;
                        localData[atom2].force.y += delta.y;
                        localData[atom2].force.z += delta.z;
                        RECORD_DERIVATIVE_2
#ifdef USE_CUTOFF
                        }
#endif
#ifdef USE_EXCLUSIONS
                        excl >>= 1;
#endif
                        tj = (tj + 1) & (TILE_SIZE - 1);
                    }
                }
            }
        }
        lasty = y;
        
        // Write results.
        
        if (pos < end) {
            const unsigned int offset = x*TILE_SIZE + tgx;
            atomicAdd(&forceBuffers[offset], static_cast<unsigned long long>((long long) (force.x*0xFFFFFFFF)));
            atomicAdd(&forceBuffers[offset+PADDED_NUM_ATOMS], static_cast<unsigned long long>((long long) (force.y*0xFFFFFFFF)));
            atomicAdd(&forceBuffers[offset+2*PADDED_NUM_ATOMS], static_cast<unsigned long long>((long long) (force.z*0xFFFFFFFF)));
            STORE_DERIVATIVES_1
        }
        if (pos < end && x != y) {
            const unsigned int offset = y*TILE_SIZE + tgx;
            atomicAdd(&forceBuffers[offset], static_cast<unsigned long long>((long long) (localData[threadIdx.x].force.x*0xFFFFFFFF)));
            atomicAdd(&forceBuffers[offset+PADDED_NUM_ATOMS], static_cast<unsigned long long>((long long) (localData[threadIdx.x].force.y*0xFFFFFFFF)));
            atomicAdd(&forceBuffers[offset+2*PADDED_NUM_ATOMS], static_cast<unsigned long long>((long long) (localData[threadIdx.x].force.z*0xFFFFFFFF)));
            STORE_DERIVATIVES_2
        }
        pos++;
    } while (pos < end);
    energyBuffer[blockIdx.x*blockDim.x+threadIdx.x] += energy;
}
