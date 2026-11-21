import 'dart:ffi';

import 'asr_runtime_version.dart';

class AsrRuntimeFile {
  const AsrRuntimeFile(this.name, this.bytes, this.sha256);
  final String name;
  final int bytes;
  final String sha256;
}

class AsrRuntimeSpec {
  const AsrRuntimeSpec(
    this.package,
    this.archiveDirectory,
    this.bytes,
    this.sha256,
    this.files,
  );
  static const version = asrRuntimeVersion;
  final String package, archiveDirectory, sha256;
  final int bytes;
  final List<AsrRuntimeFile> files;
}

const downloadedAsrRuntimes = <Abi, AsrRuntimeSpec>{
  Abi.androidArm64: AsrRuntimeSpec(
    'sherpa_onnx_android_arm64',
    'android/src/main/jniLibs/arm64-v8a',
    10819916,
    '155c8fbe1c4d917be13327e91c929ea3aaa0b78abc811cf76dbcbcbac730439d',
    [
      AsrRuntimeFile(
        'libonnxruntime.so',
        22249560,
        '33847ad43bffe204699fd4a27f7f3603452a8cdaf2f9a44983a0bc31ffcf2da1',
      ),
      AsrRuntimeFile(
        'libsherpa-onnx-c-api.so',
        5216240,
        'b3dfbc28e69a5876a44a6e66da7dc41af3a28d6bd3c3e8dd78efc501f1634d7e',
      ),
    ],
  ),
  Abi.androidArm: AsrRuntimeSpec(
    'sherpa_onnx_android_armeabi',
    'android/src/main/jniLibs/armeabi-v7a',
    9754879,
    'd3999189aa222ac2d820b9704f3e3e9e80b8ff1fd2725c0ebb48fd0dcad3631e',
    [
      AsrRuntimeFile(
        'libonnxruntime.so',
        15359592,
        '7a8f17a707e52e0ac3a026be319272876d9eae61f4bb19585292772d785f7744',
      ),
      AsrRuntimeFile(
        'libsherpa-onnx-c-api.so',
        3753188,
        'd6fa1130428367624304ee9281dec796301c4829727021d711cd3935069bc821',
      ),
    ],
  ),
  Abi.androidX64: AsrRuntimeSpec(
    'sherpa_onnx_android_x86_64',
    'android/src/main/jniLibs/x86_64',
    11826058,
    '1cd10fa17c7ca3afb9b48297111bb9fc5e2cbdb0507f87ab62f5f667b6c34cde',
    [
      AsrRuntimeFile(
        'libonnxruntime.so',
        25581120,
        '087e84297cad64acb823c3d901d6e0cc934e91add7cdb20da802cd1c0bea5c3e',
      ),
      AsrRuntimeFile(
        'libsherpa-onnx-c-api.so',
        5798360,
        '796d73b5ff941fabf9415b6dad2c7ee2604c0d35b4e44a7b7b4ce4e3142bc493',
      ),
    ],
  ),
  Abi.linuxX64: AsrRuntimeSpec(
    'sherpa_onnx_linux',
    'linux/x64',
    25084417,
    '83338f0f5838c32d6fb5e86ea28991f1345aa9dbf984ba6e51776ddea9916e27',
    [
      AsrRuntimeFile(
        'libonnxruntime.so',
        27026609,
        '4b3607aebd1784b26b6f9b20e4bd974c7ab8287043e4d095cb7d2cb40b5e566e',
      ),
      AsrRuntimeFile(
        'libsherpa-onnx-c-api.so',
        5776528,
        'f4aef0f40389c60d79d131a9259dda806425f6a1d7b27501f28140eea0ebf27b',
      ),
    ],
  ),
  Abi.linuxArm64: AsrRuntimeSpec(
    'sherpa_onnx_linux',
    'linux/aarch64',
    25084417,
    '83338f0f5838c32d6fb5e86ea28991f1345aa9dbf984ba6e51776ddea9916e27',
    [
      AsrRuntimeFile(
        'libonnxruntime.so',
        34606912,
        'cfc800d4438f15e8d9017521326776ca7117d8783cb847ccccc2fc61ac4d540f',
      ),
      AsrRuntimeFile(
        'libsherpa-onnx-c-api.so',
        5233368,
        'b83483d9173fb84bb1ec82e07a56bd896ba98f147f4061b07a579350031a7025',
      ),
    ],
  ),
  Abi.windowsX64: AsrRuntimeSpec(
    'sherpa_onnx_windows',
    'windows/x64',
    17211266,
    '89c6d176c474ddedcc255c36ca77a7128d4158634e6557d0fc0882a9161f68be',
    [
      AsrRuntimeFile(
        'onnxruntime.dll',
        17799168,
        '7f66f939a881baf4f46a2216496798edf4a1429878b646d12674aa62f27d8a25',
      ),
      AsrRuntimeFile(
        'sherpa-onnx-c-api.dll',
        4775424,
        '14e14b118fa3bde3eb0aa9cc651d47defa1e5280f2b22dfa172a74d1428f87cb',
      ),
    ],
  ),
  Abi.windowsArm64: AsrRuntimeSpec(
    'sherpa_onnx_windows',
    'windows/arm64',
    17211266,
    '89c6d176c474ddedcc255c36ca77a7128d4158634e6557d0fc0882a9161f68be',
    [
      AsrRuntimeFile(
        'onnxruntime.dll',
        17635328,
        '968d081836cad9af537105f59e34d4997bca2ce6d78ff39d3e47660620e8a642',
      ),
      AsrRuntimeFile(
        'sherpa-onnx-c-api.dll',
        4862464,
        'd0157161c741f3462e63e362a7f9c8fff0f15ed402013ed3df80dc5626938c1e',
      ),
    ],
  ),
};
