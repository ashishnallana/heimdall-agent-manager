//! Windows only: one Job Object per PTY session, the analogue of the Unix
//! session's process group. Killing the session terminates the job, so the
//! whole child tree goes (not just the direct child), and closing the last job
//! handle (host dropped / daemon exit) kills whatever is left.

use std::sync::Arc;

use portable_pty::{Child, ChildKiller};
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};

/// Exit code given to processes killed through the job.
const KILLED_EXIT_CODE: u32 = 1;

#[derive(Debug)]
struct Job(HANDLE);

// A job handle is a plain kernel handle, usable from any thread.
unsafe impl Send for Job {}
unsafe impl Sync for Job {}

impl Job {
    /// Create a kill-on-close job and put `process` in it.
    fn assign(process: HANDLE) -> std::io::Result<Job> {
        unsafe {
            let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if handle.is_null() {
                return Err(std::io::Error::last_os_error());
            }
            let job = Job(handle);
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const std::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            ) == 0
                || AssignProcessToJobObject(job.0, process) == 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(job)
        }
    }

    fn terminate(&self) -> std::io::Result<()> {
        if unsafe { TerminateJobObject(self.0, KILLED_EXIT_CODE) } == 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

/// A [`ChildKiller`] that terminates the session's whole job, then the direct
/// child (in case it was not in the job).
#[derive(Debug)]
struct JobKiller {
    job: Arc<Job>,
    inner: Box<dyn ChildKiller + Send + Sync>,
}

impl ChildKiller for JobKiller {
    fn kill(&mut self) -> std::io::Result<()> {
        let res = self.job.terminate();
        let _ = self.inner.kill();
        res
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(JobKiller {
            job: Arc::clone(&self.job),
            inner: self.inner.clone_killer(),
        })
    }
}

/// Put `child` in a fresh job and return a killer for the whole tree. Falls
/// back to `killer` (direct child only) if the job cannot be set up.
///
/// The child is assigned right after it starts, so a grandchild it spawned in
/// that instant would escape the job.
pub fn job_killer(
    child: &(dyn Child + Send + Sync),
    killer: Box<dyn ChildKiller + Send + Sync>,
) -> Box<dyn ChildKiller + Send + Sync> {
    let Some(handle) = child.as_raw_handle() else {
        return killer;
    };
    match Job::assign(handle as HANDLE) {
        Ok(job) => Box::new(JobKiller {
            job: Arc::new(job),
            inner: killer,
        }),
        Err(e) => {
            eprintln!("[ham-pty-host] could not create job object: {e}; only the direct child will be killed");
            killer
        }
    }
}
