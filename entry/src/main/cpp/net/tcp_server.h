#ifndef KDECONNECT_TCP_SERVER_H
#define KDECONNECT_TCP_SERVER_H

#include "net_types.h"

namespace kdeconnect {

class TcpServer {
public:
    TcpServer() = default;
    ~TcpServer();

    TcpServer(const TcpServer &) = delete;
    TcpServer &operator=(const TcpServer &) = delete;

    bool listen(uint16_t port);
    void close();

    int fd() const { return fd_; }
    uint16_t port() const { return port_; }
    int accept();

private:
    int fd_ = -1;
    uint16_t port_ = 0;
};

} // namespace kdeconnect

#endif
