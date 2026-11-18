WhisperBridge - whisper.cpp as a Godot GDExtension (v2.0 phone speech recognition, docs/v200_phone_design.md section 1)

What is here
  CMakeLists.txt                 one CMake build: godot-cpp + whisper.cpp/ggml (static) + the bridge -> one shared library
  build.ps1                      the one-line build (checks pinned commits and the NDK first)
  whisper_bridge.gdextension.in  template; build.ps1 writes godot\whisper_bridge.gdextension from it (generated, NOT tracked)
  BUILD_INFO.json                pinned commits, NDK version, size and sha256 of each built library (written by build.ps1)
  THIRD_PARTY.txt                licenses
  src\                           register_types.*, whisper_bridge.*  (class WhisperBridge : RefCounted, contract in design 1.4),
                                 model_check.* (model file check, no Godot code), wb_guard.* (catches C++ exceptions of whisper.cpp)
Tracked: only the files above. NOT tracked (see .gitignore): native\_deps\, build folders, godot\bin\ (the .so/.dll),
godot\whisper_bridge.gdextension, models, WAV files.

Pinned sources (native\_deps\, git clone + checkout; build.ps1 refuses any other commit)
  whisper.cpp  v1.9.5  d1be6fde11ac6e0407606b4e42fe72d34add8037   https://github.com/ggml-org/whisper.cpp
  godot-cpp    godot-4.5-stable  e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77   https://github.com/godotengine/godot-cpp
  (godot-cpp has no 4.6 tag yet; an extension built for 4.5 loads in Godot 4.6.3. compatibility_minimum is "4.5".)
  Android NDK 28.1.13356709 (r28b)

Build (Windows PowerShell; <sdk> = the Android SDK folder that contains ndk\28.1.13356709)
  powershell -ExecutionPolicy Bypass -File native\whisper_bridge\build.ps1 -Target android-arm64 -Out <build folder> -AndroidSdk <sdk>
  powershell -ExecutionPolicy Bypass -File native\whisper_bridge\build.ps1 -Target windows-x64   -Out <build folder>
  Android needs cmake and ninja on PATH. Windows needs Visual Studio 2022 C++ tools AND a Windows 10/11 SDK.
  Results: godot\bin\libwhisper_bridge.android.arm64.so (about 1.9 MB), godot\bin\whisper_bridge.windows.x86_64.dll,
  godot\whisper_bridge.gdextension (lists only the libraries that exist). Then run  godot --headless --path godot --import  once.
  The Windows DLL is for tests/calibration on the PC only; the PC app does not ship it.

Library facts (checked on the arm64 build)
  ELF AArch64, NEEDED = libm.so libdl.so libc.so only (c++ is linked statically, no libc++_shared.so from this library),
  all LOAD segments aligned 2**14 (16 KB pages), only whisper_bridge_init is exported.
  CPU code is generic armv8-a (NEON). No dotprod/i8mm build: it would crash with "illegal instruction" on older SoCs.

How it ends up in the APK (no Gradle build): Godot's normal Android export (gradle_build/use_gradle_build=false, arm64 only) copies
  the .so named in the .gdextension to lib/arm64-v8a/ uncompressed. export_presets.cfg is not changed.

Safety (why a damaged file cannot crash the app)
  - load_model() first walks the whole model file (model_check.cpp): magic, hyper-parameters, mel filters, vocabulary, every tensor
    header; each described byte must lie inside the file and the file must end exactly after the last tensor. Cut-off files,
    wrong magic, extra bytes, tiny/empty files are refused (load_model returns an error, is_loaded() stays false). Reason text:
    WhisperBridge.check_model(path) = ok | cant_open | too_small | bad_magic | bad_hparams | bad_filters | bad_vocab | bad_tensor |
    truncated | no_tensors. (whisper.cpp alone ignores short reads and even accepts a file with no tensors.)
  - whisper_init/whisper_full run through wb_guard.cpp (compiled with exceptions): a thrown C++ exception becomes an error.
  - The model name string has its own mutex; the thread count is always 1..16.
  - Static helpers: cpu_features() (from getauxval, no /proc access needed), memory_info() ({peak_kb, rss_kb}).

Behaviour notes (details: design 1.4)
  - WhisperBridge.transcribe() blocks: call it from a Thread. One model, one transcription at a time; a second call waits.
  - abort() is safe from any thread; it only applies to the transcription that is running.
  - WAV: PCM16 or float32, 1-2 channels, 8-48 kHz. A file whose data chunk is longer than the file (cut off) is "bad_wav".
    A streamed WAV (data size 0 or 0xFFFFFFFF) is read to the end of the file.
  - Silence rule (same as the PC server): fewer than 1600 samples at 16 kHz or peak < 0.003 -> ok:true, text "", words [].
  - Nothing is logged: whisper/ggml log output is dropped; no text, path or audio is written anywhere.

Tests
  godot\tests\native_bridge_test.tscn (needs the Windows DLL, a model and the synthesized WAV set; see the header of the script).
