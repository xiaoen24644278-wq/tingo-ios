//! Android 专用桥：录音、解码、AAC 压缩、HTML→PDF 由 Kotlin 侧（`TingoAudio.kt`）完成。
//!
//! 与 iOS 的区别：Android 上 Rust 不能直接引用 C 符号（Kotlin 侧也没有 `@_cdecl`），
//! 所以走 JNI 的另一个方向——Kotlin 在启动时把 `JavaVM` 交给这里保存（`TingoAudio.init()`），
//! Rust 之后 attach 到 Java 线程、反射调用 `com.hui.ting.TingoAudio` 的静态方法。
//!
//! 调用全是低频操作（开始/停止录音、解码一次、压缩一次、导出一次），
//! 每 5 秒一次的 `elapsed` 也在其中，attach/detach 的开销可以忽略。

#![cfg(target_os = "android")]

use std::sync::OnceLock;

use jni::objects::{JObject, JString, JValue};
use jni::{JNIEnv, JavaVM};

/// 类名固定，和 Kotlin 侧 `object TingoAudio` 的包名保持一致（bundle id = com.hui.ting）。
const CLASS: &str = "com/hui/ting/TingoAudio";

static VM: OnceLock<JavaVM> = OnceLock::new();

/// Kotlin `object TingoAudio` 初始化时调用（第一次反射访问触发），把 JavaVM 交过来。
/// 注意：Kotlin 的 `external fun initNative()` 是实例方法，所以这里是 `JObject` 不是 `JClass`。
#[no_mangle]
pub extern "system" fn Java_com_hui_ting_TingoAudio_initNative<'local>(
    env: JNIEnv<'local>,
    _this: JObject<'local>,
) {
    if let Ok(vm) = env.get_java_vm() {
        let _ = VM.set(vm);
    }
}

/// 取一次 JavaVM；Kotlin 还没 init 时返回错误而不是 panic。
fn vm() -> Result<&'static JavaVM, String> {
    VM.get().ok_or_else(|| "Android 音频桥还没初始化（TingoAudio.init 没被调用）".to_string())
}

fn err_from(env: &mut JNIEnv, call: &str) -> String {
    // 取 Kotlin 侧的 lastError 字符串
    let msg = (|| -> Option<String> {
        let cls = env.find_class(CLASS).ok()?;
        let v = env
            .call_static_method(cls, "lastError", "()Ljava/lang/String;", &[])
            .ok()?;
        let obj = v.l().ok()?;
        if obj.is_null() {
            return None;
        }
        let s: String = env.get_string(&JString::from(obj)).ok()?.into();
        Some(s)
    })()
    .unwrap_or_default();
    if msg.is_empty() {
        format!("Android 音频桥调用失败：{call}")
    } else {
        msg
    }
}

/// 调用一个返回 Int（0=成功）的静态方法。
fn call_int(method: &str, sig: &str, args: &[JValue]) -> Result<(), String> {
    let vm = vm()?;
    let mut env = vm
        .attach_current_thread()
        .map_err(|e| format!("attach 到 Java 线程失败：{e}"))?;
    let cls = env
        .find_class(CLASS)
        .map_err(|e| format!("找不到 {CLASS}：{e}"))?;
    let ret = env
        .call_static_method(cls, method, sig, args)
        .map_err(|e| format!("调用 {method} 抛异常：{e}"))?;
    let code = ret.i().unwrap_or(-1);
    if code == 0 {
        Ok(())
    } else {
        Err(err_from(&mut env, method))
    }
}

/// 调用一个返回 String 的静态方法。
fn call_string(method: &str) -> Result<String, String> {
    let vm = vm()?;
    let mut env = vm
        .attach_current_thread()
        .map_err(|e| format!("attach 到 Java 线程失败：{e}"))?;
    let cls = env
        .find_class(CLASS)
        .map_err(|e| format!("找不到 {CLASS}：{e}"))?;
    let v = env
        .call_static_method(cls, method, "()Ljava/lang/String;", &[])
        .map_err(|e| format!("调用 {method} 抛异常：{e}"))?;
    let obj = v.l().map_err(|e| e.to_string())?;
    if obj.is_null() {
        return Ok(String::new());
    }
    env.get_string(&JString::from(obj))
        .map(|s| s.into())
        .map_err(|e| e.to_string())
}

fn call_double(method: &str) -> f64 {
    let Ok(vm) = vm() else { return 0.0 };
    let Ok(mut env) = vm.attach_current_thread() else { return 0.0 };
    let Ok(cls) = env.find_class(CLASS) else { return 0.0 };
    match env.call_static_method(cls, method, "()D", &[]) {
        Ok(v) => v.d().unwrap_or(0.0),
        Err(_) => 0.0,
    }
}

/// 麦克风授权状态："granted" / "denied" / "undetermined"
pub fn mic_status() -> &'static str {
    match call_int_status("micStatus") {
        0 => "granted",
        1 => "denied",
        _ => "undetermined",
    }
}

/// 调一个返回 Int 的 Kotlin 静态方法，拿原始返回值
fn call_int_status(method: &str) -> i32 {
    let Ok(vm) = vm() else { return -1 };
    let Ok(mut env) = vm.attach_current_thread() else { return -1 };
    let Ok(cls) = env.find_class(CLASS) else { return -1 };
    match env.call_static_method(cls, method, "()I", &[]) {
        Ok(v) => v.i().unwrap_or(-1),
        Err(_) => -1,
    }
}

pub fn setup() -> Result<(), String> {
    let vm = vm()?;
    let mut env = vm
        .attach_current_thread()
        .map_err(|e| format!("attach 到 Java 线程失败：{e}"))?;
    let cls = env
        .find_class(CLASS)
        .map_err(|e| format!("找不到 {CLASS}：{e}"))?;
    let ret = env
        .call_static_method(cls, "setup", "()I", &[])
        .map_err(|e| e.to_string())?;
    if ret.i().unwrap_or(-1) == 0 {
        Ok(())
    } else {
        Err(err_from(&mut env, "setup"))
    }
}

pub fn rec_start(dir: &std::path::Path) -> Result<(), String> {
    let vm = vm()?;
    let mut env = vm
        .attach_current_thread()
        .map_err(|e| format!("attach 到 Java 线程失败：{e}"))?;
    let a = env.new_string(dir.to_string_lossy()).map_err(|e| e.to_string())?;
    let cls = env.find_class(CLASS).map_err(|e| e.to_string())?;
    let ret = env
        .call_static_method(
            cls,
            "startRecording",
            "(Ljava/lang/String;)I",
            &[JValue::Object(a.as_ref())],
        )
        .map_err(|e| e.to_string())?;
    if ret.i().unwrap_or(-1) == 0 {
        Ok(())
    } else {
        Err(err_from(&mut env, "startRecording"))
    }
}

pub fn rec_stop() {
    let _ = call_int("stopRecording", "()I", &[]);
}

pub fn rec_elapsed() -> f64 {
    call_double("elapsed")
}

/// 录音过程中的错误（权限被收回、麦克风被占用），取一次就清空。
pub fn take_error() -> Option<String> {
    call_string("takeError").ok().filter(|s| !s.is_empty())
}

pub fn decode(input: &std::path::Path, out: &std::path::Path) -> Result<(), String> {
    let vm = vm()?;
    let mut env = vm
        .attach_current_thread()
        .map_err(|e| format!("attach 到 Java 线程失败：{e}"))?;
    let a = env.new_string(input.to_string_lossy()).map_err(|e| e.to_string())?;
    let b = env.new_string(out.to_string_lossy()).map_err(|e| e.to_string())?;
    let cls = env.find_class(CLASS).map_err(|e| e.to_string())?;
    let ret = env
        .call_static_method(
            cls,
            "decodeToWav",
            "(Ljava/lang/String;Ljava/lang/String;)I",
            &[JValue::Object(a.as_ref()), JValue::Object(b.as_ref())],
        )
        .map_err(|e| e.to_string())?;
    if ret.i().unwrap_or(-1) == 0 {
        Ok(())
    } else {
        Err(err_from(&mut env, "decodeToWav"))
    }
}

pub fn encode_aac(input: &std::path::Path, out: &std::path::Path) -> Result<(), String> {
    let vm = vm()?;
    let mut env = vm
        .attach_current_thread()
        .map_err(|e| format!("attach 到 Java 线程失败：{e}"))?;
    let a = env.new_string(input.to_string_lossy()).map_err(|e| e.to_string())?;
    let b = env.new_string(out.to_string_lossy()).map_err(|e| e.to_string())?;
    let cls = env.find_class(CLASS).map_err(|e| e.to_string())?;
    let ret = env
        .call_static_method(
            cls,
            "encodeAac",
            "(Ljava/lang/String;Ljava/lang/String;)I",
            &[JValue::Object(a.as_ref()), JValue::Object(b.as_ref())],
        )
        .map_err(|e| e.to_string())?;
    if ret.i().unwrap_or(-1) == 0 {
        Ok(())
    } else {
        Err(err_from(&mut env, "encodeAac"))
    }
}

pub fn html_to_pdf(html: &std::path::Path, out: &std::path::Path) -> Result<(), String> {
    let vm = vm()?;
    let mut env = vm
        .attach_current_thread()
        .map_err(|e| format!("attach 到 Java 线程失败：{e}"))?;
    let a = env.new_string(html.to_string_lossy()).map_err(|e| e.to_string())?;
    let b = env.new_string(out.to_string_lossy()).map_err(|e| e.to_string())?;
    let cls = env.find_class(CLASS).map_err(|e| e.to_string())?;
    let ret = env
        .call_static_method(
            cls,
            "htmlToPdf",
            "(Ljava/lang/String;Ljava/lang/String;)I",
            &[JValue::Object(a.as_ref()), JValue::Object(b.as_ref())],
        )
        .map_err(|e| e.to_string())?;
    if ret.i().unwrap_or(-1) == 0 {
        Ok(())
    } else {
        Err(err_from(&mut env, "htmlToPdf"))
    }
}
