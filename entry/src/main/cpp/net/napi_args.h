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

// 纯文案：`op` = **导出名标签**（如 "start(config)" / "sendPayload"），由调用方按导出传入。
// 背景（CodeArts MSG127 裁决1）：前缀曾硬编码 "start(config)"；虽当时字段助手仅 JsStart 使用（未实际串错），
// 但助手是共享 static，将来被别的导出复用即会显示错误前缀 ⇒ 参数化以杜绝。文案格式与旧实现逐字一致。
inline std::string fieldTypeErrorText(const char *op, const char *field, const char *want)
{
    char msg[160];
    std::snprintf(msg, sizeof(msg), "%s: '%s' 缺失或类型错误（需要 %s）", op, field, want);
    return std::string(msg);
}

} // namespace kdeconnect::napiargs
