//
//  AVMAtomics.h
//  Lock-free state shared between the real-time audio thread and the rest of the
//  app. Written in C because Swift's own atomics (Synchronization) need macOS 15.
//

#ifndef AVM_ATOMICS_H
#define AVM_ATOMICS_H

#include <stdbool.h>

/// Opaque; defined in AVMAtomics.c. Every access is a relaxed atomic load or store:
/// no locks the audio thread could wait on, and no torn values.
typedef struct AVMMeterState AVMMeterState;

AVMMeterState *_Nullable avm_meter_create(void);
void avm_meter_destroy(AVMMeterState *_Nonnull meter);

void avm_meter_reset(AVMMeterState *_Nonnull meter);

/// Real-time thread: decaying peak, plus the "signal seen" flag if cyclePeak > 0.
void avm_meter_update(AVMMeterState *_Nonnull meter, float cyclePeak);
/// Real-time thread: feed one cycle's mean square (average of sample²). Kept as a
/// short exponential average, so the UI reads a steady RMS, not one cycle's noise.
void avm_meter_update_rms(AVMMeterState *_Nonnull meter, float cycleMeanSquare);
/// Real-time thread: one cycle's mean square in the bass and treble bands. Kept as
/// a fast-decaying peak (a hit is held, then fades within ~50 ms), so a drum hit
/// between two UI reads isn't missed.
void avm_meter_update_bands(AVMMeterState *_Nonnull meter, float bassMeanSquare, float trebleMeanSquare);
/// Real-time thread: the engine has failed to render for too long.
void avm_meter_mark_render_failure(AVMMeterState *_Nonnull meter);

float avm_meter_peak(AVMMeterState *_Nonnull meter);
/// Linear RMS (0...1) of the short exponential average above.
float avm_meter_rms(AVMMeterState *_Nonnull meter);
/// Linear RMS (0...1) of the bass and treble bands, from the decaying peaks above.
float avm_meter_bass_rms(AVMMeterState *_Nonnull meter);
float avm_meter_treble_rms(AVMMeterState *_Nonnull meter);
bool avm_meter_received_signal(AVMMeterState *_Nonnull meter);
bool avm_meter_render_failed(AVMMeterState *_Nonnull meter);

#endif
