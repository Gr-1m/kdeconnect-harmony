#include "tcp_server.h"
#include "net_log.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <cstring>

namespace kdeconnect {

TcpServer::~TcpServer()
{
    close();
}

bool TcpServer::listen(uint16_t port)
{
    fd_ = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd_ < 0) {
        LOGE("tcp socket: %s", strerror(errno));
        return false;
    }

    int yes = 1;
    setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    for (uint16_t p = port; p <= TCP_PORT_MAX; ++p) {
        struct sockaddr_in addr {};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons(p);
        if (bind(fd_, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) == 0) {
            if (::listen(fd_, MAX_UNPAIRED_CONNECTIONS) == 0) {
                port_ = p;
                LOGI("tcp listening on port %u", p);
                return true;
            }
        }
    }

    LOGE("tcp bind failed for ports %u-%u", port, TCP_PORT_MAX);
    ::close(fd_);
    fd_ = -1;
    return false;
}

void TcpServer::close()
{
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
}

int TcpServer::accept()
{
    struct sockaddr_in addr {};
    socklen_t len = sizeof(addr);
    int fd = ::accept4(fd_, reinterpret_cast<struct sockaddr *>(&addr), &len,
                       SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
        LOGE("accept: %s", strerror(errno));
    }
    return fd;
}

} // namespace kdeconnect
