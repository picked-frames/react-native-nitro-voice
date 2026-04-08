#include <jni.h>
#include <fbjni/fbjni.h>
#include "NitroVoiceOnLoad.hpp"

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  return facebook::jni::initialize(vm, []() {
    margelo::nitro::nitrovoice::registerAllNatives();
  });
}
