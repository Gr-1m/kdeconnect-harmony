// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 最小日志封装：设备侧走 hilog，host 测试走 stderr。
//!
//! hilog 的隐私策略会把非 `%{public}` 参数掩成 `<private>`，故这里只用
//! `%{public}s` 打印一次性格式化好的整行。

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Debug,
    Info,
    Warn,
    Error,
}

#[cfg(target_env = "ohos")]
mod imp {
    use super::Level;
    use std::ffi::CString;
    use std::os::raw::{c_char, c_int, c_uint};

    #[link(name = "hilog_ndk.z")]
    extern "C" {
        fn OH_LOG_Print(
            log_type: c_int,
            level: c_int,
            domain: c_uint,
            tag: *const c_char,
            fmt: *const c_char,
            ...
        ) -> c_int;
    }

    pub fn write(level: Level, message: &str) {
        let code = match level {
            Level::Debug => 3,
            Level::Info => 4,
            Level::Warn => 5,
            Level::Error => 6,
        };
        let Ok(msg) = CString::new(message) else {
            return;
        };
        let tag = c"KDEConnect";
        let fmt = c"%{public}s";
        // 签名：OH_LOG_Print(type, level, domain, tag, fmt, ...)
        // type = LOG_APP(0)，domain = 0x0001（与既有 C++ 日志一致）。
        // SAFETY: 所有指针在调用期间有效；变参仅传一个 `const char*`。
        unsafe {
            OH_LOG_Print(0, code, 0x0001, tag.as_ptr(), fmt.as_ptr(), msg.as_ptr());
        }
    }
}

#[cfg(not(target_env = "ohos"))]
mod imp {
    use super::Level;

    pub fn write(level: Level, message: &str) {
        let label = match level {
            Level::Debug => "D",
            Level::Info => "I",
            Level::Warn => "W",
            Level::Error => "E",
        };
        eprintln!("[{label}] {message}");
    }
}

pub fn write(level: Level, message: String) {
    imp::write(level, &message);
}

#[macro_export]
macro_rules! logd {
    ($($arg:tt)*) => {
        $crate::log::write($crate::log::Level::Debug, format!($($arg)*))
    };
}

#[macro_export]
macro_rules! logi {
    ($($arg:tt)*) => {
        $crate::log::write($crate::log::Level::Info, format!($($arg)*))
    };
}

#[macro_export]
macro_rules! logw {
    ($($arg:tt)*) => {
        $crate::log::write($crate::log::Level::Warn, format!($($arg)*))
    };
}

#[macro_export]
macro_rules! loge {
    ($($arg:tt)*) => {
        $crate::log::write($crate::log::Level::Error, format!($($arg)*))
    };
}
