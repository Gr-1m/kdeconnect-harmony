// SPDX-License-Identifier: GPL-2.0-or-later
//
// NAPI 取参校验的**纯判定层**（不含任何 napi_* 调用）——T1 单测目标。
//
// 背景（代码评审 F1 / AtomCode MSG112 T1）：`napi_exports.cpp` 的取参路径必须
//   ① 字段缺失 或 ② 类型不符 ⇒ 抛 TypeError（JS 侧立刻可见），调用方随即 return nullptr；
// 旧实现静默回落默认值，导致「JS 传错参数」表现为「native 悄悄用默认值」，失败原因被吞掉。
// 该约定此前只靠集成测试兜底 —— 这里把**判定**与**文案**抽成纯函数，host 单测即可锁定，
// 防止回退（判定逻辑与文案改动都会被 tests/test_main.cpp 立即拦下）。

#pragma once

#include <cstdio>
#include <string>

namespace kdeconnect::napiargs {

// 实参类型标签：与 napi_valuetype 一一对应，但**不引入 napi 头**，便于 host 单测。
enum class ArgTag {
    Undefined = 0,
    Null,
    Boolean,
    Number,
    String,
    Symbol,
    Object,
    Function,
    External,
    BigInt,
    Unknown,
};

enum class ArgCheck {
    Ok = 0,
    Missing,    // 属性缺失（或取属性本身失败）
    WrongType,  // 属性存在但类型不符
};

// 纯判定：present=属性是否取到；got=实际类型；want=期望类型。
inline ArgCheck checkArg(bool present, ArgTag got, ArgTag want)
{
    if (!present) {
        return ArgCheck::Missing;
    }
    return got == want ? ArgCheck::Ok : ArgCheck::WrongType;
}

// 纯文案：与既有 TypeError 文案**逐字一致**（测试即锁定该约定）。
// 注：前缀 "start(config)" 为历史遗留（原实现只在 JsStart 内使用后被各导出复用）；
//     是否改为「按导出名»由 CodeArts 裁决，本层只负责保持现有文案不变。
inline std::string fieldTypeErrorText(const char *field, const char *want)
{
    char msg[160];
    std::snprintf(msg, sizeof(msg), "start(config): '%s' 缺失或类型错误（需要 %s）", field, want);
    return std::string(msg);
}

} // namespace kdeconnect::napiargs
