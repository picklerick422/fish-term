// SSH stub — compiled when WAND_ENABLE_SSH is OFF.
//
// This lets the native module build for P1 (wand-agent WebSocket transport only)
// WITHOUT third_party/libssh2 + third_party/mbedtls present. It satisfies the
// SSHSession interface declared in ssh_session.h so that example_driver.cpp
// compiles and links unchanged.
//
// For P2 (native SSH), turn the option ON:
//     -DWAND_ENABLE_SSH=ON
// which builds the real ssh_session.cpp against libssh2/mbedTLS instead.

#include "ssh_session.h"

SSHSession::SSHSession()
    : m_socketFd(-1),
      m_session(nullptr),
      m_channel(nullptr),
      m_connected(false),
      m_running(false) {}

SSHSession::~SSHSession() {
    disconnect();
}

bool SSHSession::connect(const std::string& /*host*/, int /*port*/,
                         const std::string& /*user*/, const std::string& /*password*/,
                         int /*cols*/, int /*rows*/, std::string& error) {
    error = "SSH transport not built in this configuration "
            "(rebuild with -DWAND_ENABLE_SSH=ON)";
    return false;
}

void SSHSession::disconnect() {
    m_connected.store(false);
    m_running.store(false);
}

bool SSHSession::write(const char* /*data*/, size_t /*len*/) {
    return false;
}

void SSHSession::resize(int /*cols*/, int /*rows*/) {}

void SSHSession::readLoop() {}
