import Darwin
import Foundation
import Logging

extension CoffeeKit {
    /// Set up kqueue, pipe, and spawn the background monitor.
    func startWatchingPID(_ pid: pid_t) throws {
        if processWatchingTask != nil {
            stopWatchingPIDInternal()
        }

        // Create shutdown pipe
        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else {
            let err = String(cString: strerror(errno))
            throw CaffeinationError.pipeCreationFailed(error: err)
        }
        kqueueShutdownPipe = (fds[0], fds[1])

        // Set write end non-blocking
        let flags = fcntl(fds[1], F_GETFL)
        guard flags != -1,
            fcntl(fds[1], F_SETFL, flags | O_NONBLOCK) != -1
        else {
            let err = String(cString: strerror(errno))
            closePipeFDs()
            throw CaffeinationError.fcntlFailed(error: err)
        }

        // Create kqueue
        let kq = kqueue()
        guard kq != -1 else {
            let err = String(cString: strerror(errno))
            closePipeFDs()
            throw CaffeinationError.kqueueCreationFailed(error: err)
        }
        kqueueDescriptor = kq

        // Register process‐exit and pipe‐read events
        let procEvt = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        let pipeEvt = kevent(
            ident: UInt(kqueueShutdownPipe.read),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE),
            fflags: 0,
            data: 0,
            udata: nil
        )

        guard kevent(kq, [procEvt, pipeEvt], 2, nil, 0, nil) != -1
        else {
            let err = String(cString: strerror(errno))
            closeKQueueFD()
            closePipeFDs()
            throw CaffeinationError.kqueueEventRegistrationFailed(error: err)
        }

        // Launch detached monitor
        let capKQ = kqueueDescriptor
        let capRFD = kqueueShutdownPipe.read
        let capPID = pid
        let capLog = logger

        processWatchingTask = Task.detached(priority: .utility) { [weak self] in
            if let actor = self {
                await actor.runKqueueMonitorLoop(
                    kq: capKQ,
                    pipeReadFD: capRFD,
                    watchedPID: capPID,
                    taskLogger: capLog
                )
            } else {
                capLog.info("Actor gone before watcher started.")
                if capKQ != -1 { close(capKQ) }
                if capRFD != -1 { close(capRFD) }
            }
        }
        logger.debug("Kqueue monitor started.")
    }

    /// Tear down the monitor, cancel task, close FDs.
    func stopWatchingPIDInternal() {
        guard let task = processWatchingTask else { return }
        logger.debug("Stopping kqueue monitor...")
        task.cancel()
        processWatchingTask = nil

        if kqueueShutdownPipe.write != -1 {
            _ = write(kqueueShutdownPipe.write, [UInt8(0)], 1)
        }
        closeKQueueFD()
        closePipeFDs()
        logger.debug("Kqueue resources cleaned up.")
    }

    fileprivate func closeKQueueFD() {
        if kqueueDescriptor != -1 {
            close(kqueueDescriptor)
            kqueueDescriptor = -1
        }
    }

    fileprivate func closePipeFDs() {
        if kqueueShutdownPipe.read != -1 {
            close(kqueueShutdownPipe.read)
            kqueueShutdownPipe.read = -1
        }
        if kqueueShutdownPipe.write != -1 {
            close(kqueueShutdownPipe.write)
            kqueueShutdownPipe.write = -1
        }
    }

    /// Background loop: waits on kqueue for process exit or pipe signal.
    fileprivate func runKqueueMonitorLoop(
        kq: CInt,
        pipeReadFD: CInt,
        watchedPID: pid_t,
        taskLogger: Logger
    ) async {
        taskLogger.debug(
            "Monitor loop started.",
            metadata: [
                "kq": .stringConvertible(kq),
                "pipeFD": .stringConvertible(pipeReadFD),
            ])

        var event = kevent()
        var keep = true

        while keep && !Task.isCancelled {
            var timeout = timespec(tv_sec: 1, tv_nsec: 0)
            let n = kevent(kq, nil, 0, &event, 1, &timeout)

            if Task.isCancelled {
                taskLogger.debug("Monitor loop cancelled.")
                break
            }

            if n > 0 {
                if event.filter == Int16(EVFILT_PROC),
                    (event.fflags & NOTE_EXIT) != 0
                {
                    taskLogger.info(
                        "Watched PID exited.",
                        metadata: ["pid": .stringConvertible(event.ident)])
                    await handleProcessExit()
                    keep = false
                } else if event.filter == Int16(EVFILT_READ),
                    event.ident == UInt(pipeReadFD)
                {
                    taskLogger.debug("Received shutdown pipe signal.")
                    keep = false
                }
            } else if n < 0 {
                let err = errno
                if err != EBADF && err != EINTR {
                    taskLogger.error("kevent error \(err): \(String(cString: strerror(err)))")
                }
                keep = false
            }
        }

        taskLogger.debug(
            "Monitor loop ending.",
            metadata: ["watchedPID": .stringConvertible(watchedPID)])
    }

    /// Called on the actor when the watched process dies.
    fileprivate func handleProcessExit() async {
        logger.debug("Handling process exit in actor.")
        if isWatchingPID {
            logger.info("Process exit—calling stop().")
            await stop()
        }
    }
}
