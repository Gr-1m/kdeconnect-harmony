#ifndef KDECONNECT_WRITE_INTEREST_H
#define KDECONNECT_WRITE_INTEREST_H

#include <sys/epoll.h>
#include <cstdint>

namespace kdeconnect {

// EPOLLOUT「按需挂/摘」的**唯一实现**（S3 —— AtomCode REVIEW_HOLISTIC_BUGFIX S3）。
//
// 教训（此前在连接侧与 payload 侧各写一遍、注释各记一次；第三个 fd 类型会是第三次踩坑）：
// EPOLLET 下若**无待发内容却挂着 EPOLLOUT**，epoll_wait 会反复上报（真机 wake[payload]=31,526），
// 更糟的是边沿耗尽后读事件滞留 ⇒ FSM 停摆 ⇒ 真机现象「文件永远停在接收中」。
//
// 契约（三条，任何新 fd 类型都必须遵守）：
//   ① 只在「期望兴趣 want」与「已挂状态 armed」**不同**时下发 —— MOD 会重新武装 ET 并立即上报；
//   ② 下发时**必须恒定附加 EPOLLET**（调用方通过 evIn 传入 EPOLLIN 等基础位）；
//   ③ **下发成功才更新本地状态**（失败则下次仍会尝试，避免状态与内核不一致）。
struct WriteInterestState {
    bool armed = false;   // 当前是否已挂 EPOLLOUT（仅由本设施读写）
};

// mod(fd, events) 返回是否成功：连接侧直接用 epoll_ctl(EPOLL_CTL_MOD)，
// payload 侧经 PayloadHost::epollMod 钩子（两个宿主的下发方式不同，故以回调注入）。
template <typename ModFn>
inline void applyWriteInterest(WriteInterestState &st, int fd, bool want, uint32_t evIn,
                               ModFn &&mod)
{
    if (want == st.armed) {
        return;   // ① 状态未变：不下发
    }
    if (mod(fd, evIn | (want ? EPOLLOUT : 0u))) {
        st.armed = want;   // ③ 成功才置位
    }
}

} // namespace kdeconnect

#endif
