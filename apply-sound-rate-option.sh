#!/bin/bash
# gpSP: wire up the gpsp_sound_rate core option (patch 2/2).
# Substring-anchored edits via perl: immune to CRLF, indentation, line numbers.
# Run from the repo root in MINGW64 git-bash:  bash apply-sound-rate-option.sh
set -e

test -f libretro/libretro.c || { echo "run from the gpsp repo root"; exit 1; }
git am --abort 2>/dev/null || true
git checkout -- libretro/ 2>/dev/null || true
rm -f libretro/*.rej *.rej

# ---------- 1) helper function, inserted after the audio statics ----------
cat > /tmp/gpsp_sr_helper.c <<'EOF'

/* Apply the gpsp_sound_rate core option. reinit_env is non-NULL only for
 * mid-session changes (retro_run variable check), where issuing
 * RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO is legal; at load time the new rate
 * is picked up by the normal av_info and buffer init paths. */
static void gpsp_apply_sound_rate(const char *value, retro_environment_t reinit_env)
{
   u32 new_bits = (value && !strcmp(value, "32768")) ? 15 : 16;

   if (new_bits == sound_freq_bits)
      return;

   sound_freq_bits = new_bits;
   sound_frequency = 1u << new_bits;
   audio_samples_per_frame   = (float)sound_frequency / (float)(GBA_FPS);
   audio_samples_accumulator = 0.0f;

   if (reinit_env)
   {
      struct retro_system_av_info av_info;
      render_gbc_sound();          /* drain pending ticks at the old rate */
      sound_frequency_changed();   /* recompute all derived steps */
      sound_flush_ring();
      retro_get_system_av_info(&av_info);
      reinit_env(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO, &av_info);
   }
}
EOF
perl -0pi -e 'BEGIN{local $/; open F,"<","/tmp/gpsp_sr_helper.c" or die; $h=<F>; close F}
  die "anchor: audio_samples_accumulator static not found\n"
    unless s/(static\s+float\s+audio_samples_accumulator[^\n]*\n)/$1$h/;
' libretro/libretro.c
echo "[1/6] helper inserted"

# ---------- 2) report the runtime rate to the frontend ----------
perl -pi -e 's/(info->timing\.sample_rate\s*=\s*)GBA_SOUND_FREQUENCY/${1}sound_frequency/' libretro/libretro.c
grep -q 'info->timing.sample_rate = sound_frequency' libretro/libretro.c \
  || { echo "FAILED: sample_rate swap"; exit 1; }
echo "[2/6] sample_rate -> sound_frequency"

# ---------- 3) per-frame count from runtime rate; buffer sized for max ----------
perl -pi -e 's/(audio_samples_per_frame\s*=\s*)\(float\)\(GBA_SOUND_FREQUENCY\)/${1}(float)sound_frequency/' libretro/libretro.c
perl -pi -e 's/^(\s*)audio_sample_buffer_size\s*=\s*\(\(u32\)audio_samples_per_frame.*?(\r?)$/${1}audio_sample_buffer_size  = (((u32)((float)(GBA_SOUND_FREQUENCY) \/ (float)(GBA_FPS))) + 1) * 2;${2}/' libretro/libretro.c
grep -q 'audio_samples_per_frame   = (float)sound_frequency' libretro/libretro.c \
  || { echo "FAILED: samples_per_frame swap"; exit 1; }
echo "[3/6] buffer sized for compile-time max rate"

# ---------- 4) read the option in check_variables ----------
cat > /tmp/gpsp_sr_check.c <<'EOF'
   {
      static int sound_rate_configured = 0;
      struct retro_variable svar = { "gpsp_sound_rate", NULL };
      environ_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &svar);
      gpsp_apply_sound_rate(svar.value, sound_rate_configured ? environ_cb : NULL);
      sound_rate_configured = 1;
   }

EOF
perl -0pi -e 'BEGIN{local $/; open F,"<","/tmp/gpsp_sr_check.c" or die; $h=<F>; close F}
  die "anchor: gpsp_frameskip var.key not found in check_variables\n"
    unless s/(\n)(\s*var\.key\s*=\s*"gpsp_frameskip")/$1$h$2/;
' libretro/libretro.c
echo "[4/6] check_variables reads gpsp_sound_rate (first call silent, later calls reinit AV)"

# ---------- 5) option definition (auto-detects v1 vs v2 options format) ----------
if grep -q 'retro_core_option_v2_definition' libretro/libretro_core_options.h; then
cat > /tmp/gpsp_sr_opt.c <<'EOF'
   {
      "gpsp_sound_rate",
      "Sound Output Rate (Hz)",
      NULL,
      "Internal audio rendering rate. Both values keep audio timing exact. 65536 renders the full mixer bandwidth; 32768 matches the bandwidth of real hardware's default PWM output and halves audio mixing work.",
      NULL,
      NULL,
      {
         { "65536", NULL },
         { "32768", NULL },
         { NULL, NULL },
      },
      "65536"
   },
EOF
else
cat > /tmp/gpsp_sr_opt.c <<'EOF'
   {
      "gpsp_sound_rate",
      "Sound Output Rate (Hz)",
      "Internal audio rendering rate. Both values keep audio timing exact. 65536 renders the full mixer bandwidth; 32768 matches the bandwidth of real hardware's default PWM output and halves audio mixing work.",
      {
         { "65536", NULL },
         { "32768", NULL },
         { NULL, NULL },
      },
      "65536"
   },
EOF
fi
perl -0pi -e 'BEGIN{local $/; open F,"<","/tmp/gpsp_sr_opt.c" or die; $h=<F>; close F}
  die "anchor: gpsp_frameskip entry not found in options header\n"
    unless s/(\n)(\s*\{\s*\r?\n\s*"gpsp_frameskip",)/$1$h$2/;
' libretro/libretro_core_options.h
echo "[5/6] option registered"

# ---------- 6) summary ----------
echo "[6/6] remaining MANUAL step (one line):"
echo "      in libretro/libretro.c retro_unserialize(), after the state load"
echo "      succeeds, add:   sound_frequency_changed();"
echo "      (gates cross-rate savestate portability only; feature works without it)"
echo
grep -n "gpsp_sound_rate\|gpsp_apply_sound_rate\|sound_frequency_changed" \
  libretro/libretro.c libretro/libretro_core_options.h | head -20
