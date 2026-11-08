fn main() {
    // 模块名必须与最终 .so 文件名一致（libkdeconnect_napi.so）。
    println!("cargo:rustc-env=NAPI_BUILD_TARGET_NAME=kdeconnect_napi");
    napi_build_ohos::setup();
}
