//! A hand-written HTTP/1.1 server: no framework, no async runtime, just the
//! Linux system calls. It shows roughly how fast "hello world" can go.
//!
//! - One thread per core, each with its own listening socket (SO_REUSEPORT)
//!   and its own epoll loop, so threads never share or lock anything.
//! - Edge-triggered epoll, non-blocking sockets, TCP_NODELAY.
//! - The full response (headers + body) is built once per second, when the
//!   Date header changes, and copied out as-is for every request.
//! - Pipelined requests are answered in one write.
//!
//! It is a demonstration of the ceiling, not a web server: it only answers
//! GET (404 for any path but /), and closes connections that send anything
//! else, including requests with a body.

use std::{
    io, mem, ptr, thread,
    time::{SystemTime, UNIX_EPOCH},
};

const PORT: u16 = 3010;
const BODY: &[u8] = b"Epoll   greets the world!";
const MAX_EVENTS: usize = 1024;
const READ_CHUNK: usize = 16 * 1024;
const MAX_PENDING: usize = 64 * 1024;

fn main() {
    let threads = std::env::var("WORKERS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| thread::available_parallelism().map(|n| n.get()).unwrap_or(1));
    println!("Rust (hand-written epoll, {threads} threads) listening at http://localhost:{PORT}");

    let workers: Vec<_> = (0..threads)
        .map(|_| {
            thread::spawn(|| {
                if let Err(e) = worker() {
                    eprintln!("worker failed: {e}");
                    std::process::exit(1);
                }
            })
        })
        .collect();
    for w in workers {
        let _ = w.join();
    }
}

#[derive(Default)]
struct Conn {
    input: Vec<u8>,
    output: Vec<u8>,
    written: usize,
}

fn worker() -> io::Result<()> {
    let listen_fd = listener()?;
    let ep = check(unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) })?;
    epoll_add(ep, listen_fd, libc::EPOLLIN as u32)?;

    let mut conns: Vec<Option<Conn>> = Vec::new();
    let mut events = vec![libc::epoll_event { events: 0, u64: 0 }; MAX_EVENTS];
    let mut chunk = vec![0u8; READ_CHUNK];
    let mut responses = Responses::new();

    loop {
        let n = unsafe { libc::epoll_wait(ep, events.as_mut_ptr(), MAX_EVENTS as i32, 1000) };
        if n < 0 {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
        responses.refresh();

        for i in 0..n as usize {
            let ev = events[i]; // copy: epoll_event is packed
            let fd = ev.u64 as i32;
            let flags = ev.events;
            if fd == listen_fd {
                accept_all(ep, listen_fd, &mut conns);
            } else if flags & (libc::EPOLLERR | libc::EPOLLHUP) as u32 != 0
                || !serve(fd, &mut conns, &mut chunk, &responses)
            {
                close(fd, &mut conns);
            }
        }
    }
}

/// Reads what has arrived, answers every complete request, and writes the
/// answers. Returns false when the connection should be closed.
fn serve(fd: i32, conns: &mut [Option<Conn>], chunk: &mut [u8], responses: &Responses) -> bool {
    let Some(Some(conn)) = conns.get_mut(fd as usize) else {
        return false;
    };

    loop {
        let n = unsafe { libc::read(fd, chunk.as_mut_ptr().cast(), chunk.len()) };
        if n > 0 {
            conn.input.extend_from_slice(&chunk[..n as usize]);
            if conn.input.len() > MAX_PENDING {
                return false;
            }
            if (n as usize) < chunk.len() {
                break; // short read: the socket is drained
            }
        } else if n == 0 {
            return false; // peer closed
        } else {
            match errno() {
                libc::EAGAIN => break,
                libc::EINTR => continue,
                _ => return false,
            }
        }
    }

    let mut start = 0;
    while let Some(end) = find_header_end(&conn.input[start..]) {
        let request = &conn.input[start..start + end];
        if request.starts_with(b"GET / ") {
            conn.output.extend_from_slice(&responses.ok);
        } else if request.starts_with(b"GET ") {
            conn.output.extend_from_slice(&responses.not_found);
        } else {
            return false;
        }
        start += end + 4;
    }
    conn.input.drain(..start);

    flush(fd, conn)
}

fn flush(fd: i32, conn: &mut Conn) -> bool {
    while conn.written < conn.output.len() {
        let rest = &conn.output[conn.written..];
        let n = unsafe { libc::send(fd, rest.as_ptr().cast(), rest.len(), libc::MSG_NOSIGNAL) };
        if n > 0 {
            conn.written += n as usize;
        } else if n < 0 {
            match errno() {
                libc::EAGAIN => return true, // socket full: EPOLLOUT will call us again
                libc::EINTR => continue,
                _ => return false,
            }
        } else {
            return false;
        }
    }
    conn.output.clear();
    conn.written = 0;
    true
}

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

fn accept_all(ep: i32, listen_fd: i32, conns: &mut Vec<Option<Conn>>) {
    loop {
        let fd = unsafe {
            libc::accept4(listen_fd, ptr::null_mut(), ptr::null_mut(), libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC)
        };
        if fd < 0 {
            match errno() {
                libc::EINTR | libc::ECONNABORTED => continue,
                _ => return, // EAGAIN: nothing left to accept (or out of fds: try again later)
            }
        }
        let one: libc::c_int = 1;
        unsafe {
            libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, (&one as *const libc::c_int).cast(), size_of_val(&one) as u32);
        }
        let flags = (libc::EPOLLIN | libc::EPOLLOUT | libc::EPOLLRDHUP | libc::EPOLLET) as u32;
        if epoll_add(ep, fd, flags).is_err() {
            unsafe { libc::close(fd) };
            continue;
        }
        let i = fd as usize;
        if conns.len() <= i {
            conns.resize_with(i + 1, || None);
        }
        conns[i] = Some(Conn::default());
    }
}

fn close(fd: i32, conns: &mut [Option<Conn>]) {
    if let Some(slot) = conns.get_mut(fd as usize) {
        *slot = None;
    }
    unsafe { libc::close(fd) }; // also removes it from epoll
}

fn listener() -> io::Result<i32> {
    unsafe {
        let fd = check(libc::socket(libc::AF_INET, libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC, 0))?;
        let one: libc::c_int = 1;
        for option in [libc::SO_REUSEADDR, libc::SO_REUSEPORT] {
            check(libc::setsockopt(fd, libc::SOL_SOCKET, option, (&one as *const libc::c_int).cast(), size_of_val(&one) as u32))?;
        }
        let mut addr: libc::sockaddr_in = mem::zeroed();
        addr.sin_family = libc::AF_INET as libc::sa_family_t;
        addr.sin_port = PORT.to_be();
        addr.sin_addr.s_addr = libc::INADDR_ANY;
        check(libc::bind(fd, (&addr as *const libc::sockaddr_in).cast(), size_of_val(&addr) as u32))?;
        check(libc::listen(fd, 4096))?;
        Ok(fd)
    }
}

fn epoll_add(ep: i32, fd: i32, events: u32) -> io::Result<()> {
    let mut ev = libc::epoll_event { events, u64: fd as u64 };
    check(unsafe { libc::epoll_ctl(ep, libc::EPOLL_CTL_ADD, fd, &mut ev) }).map(|_| ())
}

fn check(ret: libc::c_int) -> io::Result<libc::c_int> {
    if ret < 0 { Err(io::Error::last_os_error()) } else { Ok(ret) }
}

fn errno() -> i32 {
    io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

/// The complete responses, rebuilt only when the second (and so the Date
/// header) changes.
struct Responses {
    second: u64,
    ok: Vec<u8>,
    not_found: Vec<u8>,
}

impl Responses {
    fn new() -> Self {
        let mut r = Responses { second: u64::MAX, ok: Vec::new(), not_found: Vec::new() };
        r.refresh();
        r
    }

    fn refresh(&mut self) {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        if now == self.second {
            return;
        }
        self.second = now;
        let date = http_date(now);
        self.ok = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nDate: {date}\r\n\r\n",
            BODY.len()
        )
        .into_bytes();
        self.ok.extend_from_slice(BODY);
        self.not_found = format!("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nDate: {date}\r\n\r\n").into_bytes();
    }
}

/// Formats Unix seconds as an HTTP date, e.g. "Thu, 05 Nov 2026 12:08:41 GMT".
fn http_date(secs: u64) -> String {
    const DAYS: [&str; 7] = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]; // 1970-01-01 was a Thursday
    const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let days = (secs / 86_400) as i64;
    let (h, m, s) = (secs % 86_400 / 3600, secs % 3600 / 60, secs % 60);

    // Days since 1970 to a calendar date (Howard Hinnant's civil_from_days).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);

    format!(
        "{}, {day:02} {} {year} {h:02}:{m:02}:{s:02} GMT",
        DAYS[(days % 7) as usize],
        MONTHS[(month - 1) as usize]
    )
}

#[cfg(test)]
mod tests {
    use super::http_date;

    #[test]
    fn formats_http_dates() {
        assert_eq!(http_date(0), "Thu, 01 Jan 1970 00:00:00 GMT");
        assert_eq!(http_date(951_782_400), "Tue, 29 Feb 2000 00:00:00 GMT");
        assert_eq!(http_date(1_772_323_200), "Sun, 01 Mar 2026 00:00:00 GMT");
        assert_eq!(http_date(1_793_793_201), "Wed, 04 Nov 2026 11:53:21 GMT");
    }
}
