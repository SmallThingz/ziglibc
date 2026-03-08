#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include "expect.h"

static void init_loopback(struct sockaddr_in *addr)
{
  memset(addr, 0, sizeof(*addr));
  addr->sin_family = AF_INET;
  addr->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr->sin_port = 0;
}

int main(void)
{
  {
    struct sockaddr_in sender_addr;
    struct sockaddr_in receiver_addr;
    struct sockaddr_in peer_addr;
    socklen_t sender_len = sizeof(sender_addr);
    socklen_t receiver_len = sizeof(receiver_addr);
    socklen_t peer_len = sizeof(peer_addr);
    int sender = socket(AF_INET, SOCK_DGRAM, 0);
    int receiver = socket(AF_INET, SOCK_DGRAM, 0);
    int sndbuf = 4096;
    int optval = 0;
    socklen_t optlen = sizeof(optval);
    char rx[8];
    char text[32];

    expect(sender >= 0);
    expect(receiver >= 0);

    init_loopback(&sender_addr);
    init_loopback(&receiver_addr);

    expect(0 == bind(sender, (const struct sockaddr *)&sender_addr, sizeof(sender_addr)));
    expect(0 == bind(receiver, (const struct sockaddr *)&receiver_addr, sizeof(receiver_addr)));

    expect(0 == getsockname(sender, (struct sockaddr *)&sender_addr, &sender_len));
    expect(0 == getsockname(receiver, (struct sockaddr *)&receiver_addr, &receiver_len));
    expect(sender_addr.sin_port != 0);
    expect(receiver_addr.sin_port != 0);

    expect(0 == setsockopt(sender, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf)));
    expect(0 == getsockopt(sender, SOL_SOCKET, SO_SNDBUF, &optval, &optlen));
    expect(optlen == sizeof(optval));
    expect(optval > 0);

    expect(0 == connect(sender, (const struct sockaddr *)&receiver_addr, sizeof(receiver_addr)));
    expect(0 == connect(receiver, (const struct sockaddr *)&sender_addr, sizeof(sender_addr)));

    expect(4 == sendto(sender, "ping", 4, 0, NULL, 0));
    {
      fd_set readfds;
      struct timeval tv;
      FD_ZERO(&readfds);
      FD_SET(receiver, &readfds);
      tv.tv_sec = 0;
      tv.tv_usec = 0;
      expect(1 == select(receiver + 1, &readfds, NULL, NULL, &tv));
      expect(FD_ISSET(receiver, &readfds));
    }
    expect(4 == recvfrom(receiver, rx, sizeof(rx), 0, (struct sockaddr *)&peer_addr, &peer_len));
    expect(0 == memcmp(rx, "ping", 4));
    expect(peer_addr.sin_family == AF_INET);
    expect(peer_addr.sin_port == sender_addr.sin_port);
    expect(0 == getpeername(receiver, (struct sockaddr *)&peer_addr, &peer_len));
    expect(peer_addr.sin_port == sender_addr.sin_port);

    expect(4 == sendto(receiver, "pong", 4, 0, NULL, 0));
    expect(4 == recv(sender, rx, sizeof(rx), 0));
    expect(0 == memcmp(rx, "pong", 4));

    expect(0 == shutdown(sender, SHUT_WR));
    expect(0 == close(sender));
    expect(0 == close(receiver));

    expect(0x11223344U == ntohl(htonl(0x11223344U)));
    expect(0x3344U == ntohs(htons(0x3344U)));
    expect(inet_addr("127.0.0.1") == htonl(INADDR_LOOPBACK));
    expect(0 == strcmp("127.0.0.1", inet_ntoa((struct in_addr){ htonl(INADDR_LOOPBACK) })));

    expect(NULL != gethostbyname("localhost"));
    expect(NULL != gethostbyname("127.0.0.1"));
    expect(NULL != gethostbyaddr(&receiver_addr.sin_addr.s_addr, sizeof(receiver_addr.sin_addr.s_addr), AF_INET));
    strcpy(text, inet_ntoa(receiver_addr.sin_addr));
    expect(0 == strcmp("127.0.0.1", text));
  }

  puts("Success!");
  return 0;
}
