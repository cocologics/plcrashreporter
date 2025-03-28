/*
 * Author: Landon Fuller <landonf@plausiblelabs.com>
 *
 * Copyright (c) 2008-2009 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#if __has_include(<CrashReporter/CrashReporter.h>)
#import <CrashReporter/CrashReporter.h>
#import <CrashReporter/PLCrashReporter.h>
#else
#import "CrashReporter.h"
#import "PLCrashReporter.h"
#endif

#import "PLCrashCompatConstants.h"
#import "PLCrashFeatureConfig.h"
#import "PLCrashHostInfo.h"
#import "PLCrashSignalHandler.h"
#import "PLCrashMachExceptionServer.h"
#import "PLCrashFeatureConfig.h"
#import "PLCrashAsync.h"
#import "PLCrashLogWriter.h"
#import "PLCrashFrameWalker.h"
#import "PLCrashAsyncMachExceptionInfo.h"
#import "PLCrashReporterNSError.h"

#import <fcntl.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#import <stdatomic.h>

/** @internal
 * CrashReporter cache directory name. */
static NSString *PLCRASH_CACHE_DIR = @"com.plausiblelabs.crashreporter.data";

/** @internal
 * Crash Report file name. */
static NSString *PLCRASH_LIVE_CRASHREPORT = @"live_report.plcrash";

/** @internal
 * Directory containing crash reports queued for sending. */
static NSString *PLCRASH_QUEUED_DIR = @"queued_reports";

/**
 * @internal
 * Fatal signals to be monitored.
 */
static int monitored_signals[] = {
    SIGABRT,
    SIGBUS,
    SIGFPE,
    SIGILL,
    SIGSEGV,
    SIGTRAP
};

/** @internal
 * number of signals in the fatal signals list */
static int monitored_signals_count = (sizeof(monitored_signals) / sizeof(monitored_signals[0]));

/**
 * @internal
 * Signal handler context
 */
typedef struct signal_handler_ctx {
    /** PLCrashLogWriter instance */
    plcrash_log_writer_t writer;

    /** Path to the output file */
    const char *path;

    /** Maximum number of bytes that will be written to the crash report.  */
    NSUInteger max_report_size;

#if PLCRASH_FEATURE_MACH_EXCEPTIONS
    /* Previously registered Mach exception ports, if any. Will be left uninitialized if PLCrashReporterSignalHandlerTypeMach
     * is not enabled. */
    plcrash_mach_exception_port_set_t port_set;
#endif /* PLCRASH_FEATURE_MACH_EXCEPTIONS */
} plcrashreporter_handler_ctx_t;

/**
 * @internal
 *
 * Shared dyld image list.
 */
static plcrash_async_image_list_t shared_image_list;


/**
 * @internal
 * 
 * Signal handler context (singleton)
 */
static plcrashreporter_handler_ctx_t signal_handler_context;


/**
 * @internal
 * 
 * The optional user-supplied callbacks invoked after the crash report has been written.
 */
static PLCrashReporterCallbacks crashCallbacks = {
    .version = 0,
    .context = NULL,
    .handleSignal = NULL
};

/**
 * Write a fatal crash report.
 *
 * @param sigctx Fatal handler context.
 * @param crashed_thread The crashed thread.
 * @param thread_state The crashed thread's state.
 * @param siginfo The signal information.
 *
 * @return Returns PLCRASH_ESUCCESS on success, or an appropriate error value if the report could not be written.
 */
static plcrash_error_t plcrash_write_report (plcrashreporter_handler_ctx_t *sigctx, thread_t crashed_thread, plcrash_async_thread_state_t *thread_state, plcrash_log_signal_info_t *siginfo) {
    plcrash_async_file_t file;
    plcrash_error_t err;

    /* Open the output file */
    int fd = open(sigctx->path, O_RDWR|O_CREAT|O_TRUNC, 0644);
    if (fd < 0) {
        PLCF_DEBUG("Could not open the crashlog output file: %s", strerror(errno));
        return PLCRASH_EINTERNAL;
    }
    
    /* Initialize the output context */
    plcrash_async_file_init(&file, fd, sigctx->max_report_size);

    /* Write the crash log using the already-initialized writer */
    err = plcrash_log_writer_write(&sigctx->writer, crashed_thread, &shared_image_list, &file, siginfo, thread_state);

    /* Close the writer; this may also fail (but shouldn't) */
    if (plcrash_log_writer_close(&sigctx->writer) != PLCRASH_ESUCCESS) {
        PLCF_DEBUG("Failed to close the log writer");
        plcrash_async_file_close(&file);
        return PLCRASH_EINTERNAL;
    }
    
    /* Finished */
    if (!plcrash_async_file_flush(&file)) {
        PLCF_DEBUG("Failed to flush output file");
        plcrash_async_file_close(&file);
        return PLCRASH_EINTERNAL;
    }
    
    if (!plcrash_async_file_close(&file)) {
        PLCF_DEBUG("Failed to close output file");
        return PLCRASH_EINTERNAL;
    }

    return err;
}

/**
 * @internal
 *
 * Signal handler callback.
 */
static bool signal_handler_callback (int signal, siginfo_t *info, pl_ucontext_t *uap, void *context, PLCrashSignalHandlerCallback *next) {
    plcrashreporter_handler_ctx_t *sigctx = context;
    plcrash_async_thread_state_t thread_state;
    plcrash_log_signal_info_t signal_info;
    plcrash_log_bsd_signal_info_t bsd_signal_info;
    
    /* Remove all signal handlers -- if the crash reporting code fails, the default terminate
     * action will occur.
     *
     * NOTE: SA_RESETHAND breaks SA_SIGINFO on ARM, so we reset the handlers manually.
     * http://openradar.appspot.com/11839803
     *
     * TODO: When forwarding signals (eg, to Mono's runtime), resetting the signal handlers
     * could result in incorrect runtime behavior; we should revisit resetting the
     * signal handlers once we address double-fault handling.
     */
    for (int i = 0; i < monitored_signals_count; i++) {
        struct sigaction sa;
        
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SIG_DFL;
        sigemptyset(&sa.sa_mask);
        
        sigaction(monitored_signals[i], &sa, NULL);
    }

    /* Extract the thread state */
    plcrash_async_thread_state_mcontext_init(&thread_state, uap->uc_mcontext);
    
    /* Set up the BSD signal info */
    bsd_signal_info.signo = info->si_signo;
    bsd_signal_info.code = info->si_code;
    bsd_signal_info.address = info->si_addr;
    
    signal_info.bsd_info = &bsd_signal_info;
    signal_info.mach_info = NULL;

    /* Write the report */
    if (plcrash_write_report(sigctx, pl_mach_thread_self(), &thread_state, &signal_info) != PLCRASH_ESUCCESS)
        return false;

    /* Call any post-crash callback */
    if (crashCallbacks.handleSignal != NULL)
        crashCallbacks.handleSignal(info, uap, crashCallbacks.context);
    
    return false;
}

#if PLCRASH_FEATURE_MACH_EXCEPTIONS
/* State and callback used to generate thread state for the calling mach thread. */
struct mach_exception_callback_live_cb_ctx {
    plcrashreporter_handler_ctx_t *sigctx;
    thread_t crashed_thread;
    plcrash_log_signal_info_t *siginfo;
};

static plcrash_error_t mach_exception_callback_live_cb (plcrash_async_thread_state_t *state, void *ctx) {
    struct mach_exception_callback_live_cb_ctx *plcr_ctx = ctx;
    return plcrash_write_report(plcr_ctx->sigctx, plcr_ctx->crashed_thread, state, plcr_ctx->siginfo);
}

static kern_return_t mach_exception_callback (task_t task, thread_t thread, exception_type_t exception_type, mach_exception_data_t code, mach_msg_type_number_t code_count, void *context) {
    plcrashreporter_handler_ctx_t *sigctx = context;
    plcrash_log_signal_info_t signal_info;
    plcrash_log_bsd_signal_info_t bsd_signal_info;
    plcrash_log_mach_signal_info_t mach_signal_info;
    PLCF_UNUSED_IN_RELEASE plcrash_error_t err;

    /* Let any other registered server attempt to handle the exception */
    if (PLCrashMachExceptionForward(task, thread, exception_type, code, code_count, &sigctx->port_set) == KERN_SUCCESS)
        return KERN_SUCCESS;
    
    /* Set up the BSD signal info */
    siginfo_t si;
    if (!plcrash_async_mach_exception_get_siginfo(exception_type, code, code_count, CPU_TYPE_ANY, &si)) {
        PLCF_DEBUG("Unexpected error mapping Mach exception to a POSIX signal");
        return KERN_FAILURE;
    }

    bsd_signal_info.signo = si.si_signo;
    bsd_signal_info.code = si.si_code;
    bsd_signal_info.address = si.si_addr;

    signal_info.bsd_info = &bsd_signal_info;
    
    /* Set up the Mach signal info */
    mach_signal_info.type = exception_type;
    mach_signal_info.code = code;
    mach_signal_info.code_count = code_count;
    signal_info.mach_info = &mach_signal_info;
    
    /* Write the report */
    struct mach_exception_callback_live_cb_ctx live_ctx = {
        .sigctx = sigctx,
        .crashed_thread = thread,
        .siginfo = &signal_info
    };
    if ((err = plcrash_async_thread_state_current(mach_exception_callback_live_cb, &live_ctx)) != PLCRASH_ESUCCESS) {
        PLCF_DEBUG("Failed to write live report: %d", err);
        return KERN_FAILURE;
    }

    /* Call any post-crash callback */
    if (crashCallbacks.handleSignal != NULL) {
        /*
         * The legacy signal-based callback assumes the availability of a ucontext_t; we mock
         * an empty value here for the purpose of maintaining backwards compatibility. This behavior
         * is defined in the PLCrashReporterCallbacks API documentation.
         */
        ucontext_t uctx;
        _STRUCT_MCONTEXT mctx;
        
        /* Populate the mctx */
        plcrash_async_memset(&mctx, 0, sizeof(mctx));

        /* Configure the ucontext */
        plcrash_async_memset(&uctx, 0, sizeof(uctx));
        uctx.uc_mcsize = sizeof(mctx);
        uctx.uc_mcontext = &mctx;
    
        crashCallbacks.handleSignal(&si, &uctx, crashCallbacks.context);
    }

    return KERN_FAILURE;
}
#endif /* PLCRASH_FEATURE_MACH_EXCEPTIONS */

/**
 * @internal
 * dyld image add notification callback.
 */
static void image_add_callback (const struct mach_header *mh, intptr_t vmaddr_slide) {
    Dl_info info;
    
    /* Look up the image info */
    if (dladdr(mh, &info) == 0) {
        PLCR_LOG("%s: dladdr(%p, ...) failed", __FUNCTION__, mh);
        return;
    }

    /* Register the image */
    plcrash_nasync_image_list_append(&shared_image_list, (pl_vm_address_t) mh, info.dli_fname);
}

/**
 * @internal
 * dyld image remove notification callback.
 */
static void image_remove_callback (const struct mach_header *mh, intptr_t vmaddr_slide) {
    plcrash_nasync_image_list_remove(&shared_image_list, (uintptr_t) mh);
}


/**
 * @internal
 *
 * Uncaught exception handler. Sets the plcrash_log_writer_t's uncaught exception
 * field, and then triggers a SIGTRAP (synchronous exception) to cause a normal
 * exception dump.
 */
static void uncaught_exception_handler (NSException *exception) {
    /**
     * It is possible that another crash may occur between setting the uncaught
     * exception field, and triggering the signal handler.
     */
    static atomic_bool exception_is_handled = false;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&exception_is_handled, &expected, true)) {
        return;
    }
    
    /* Set the uncaught exception */
    plcrash_log_writer_set_exception(&signal_handler_context.writer, exception);

    /* Synchronously trigger the crash handler */
    abort();
}


@interface PLCrashReporter (PrivateMethods)

- (id) initWithBundle: (NSBundle *) bundle configuration: (PLCrashReporterConfig *) configuration;
- (id) initWithApplicationIdentifier: (NSString *) applicationIdentifier appVersion: (NSString *) applicationVersion appMarketingVersion: (NSString *) applicationMarketingVersion configuration: (PLCrashReporterConfig *) configuration;

#if PLCRASH_FEATURE_MACH_EXCEPTIONS
- (PLCrashMachExceptionServer *) enableMachExceptionServerWithPreviousPortSet: (__strong PLCrashMachExceptionPortSet **) previousPortSet
                                                                     callback: (PLCrashMachExceptionHandlerCallback) callback
                                                                      context: (void *) context
                                                                        error: (NSError **) outError;
#endif
- (plcrash_async_symbol_strategy_t) mapToAsyncSymbolicationStrategy: (PLCrashReporterSymbolicationStrategy) strategy;

- (BOOL) populateCrashReportDirectoryAndReturnError: (NSError **) outError;
- (NSString *) crashReportDirectory;
- (NSString *) queuedCrashReportDirectory;

@end


/**
 * Crash Reporter.
 *
 * A PLCrashReporter instance manages process-wide handling of crashes.
 */
@implementation PLCrashReporter {

    /** Reporter configuration */
    __strong PLCrashReporterConfig *_config;

    /** YES if the crash reporter has been enabled */
    BOOL _enabled;
    
#if PLCRASH_FEATURE_MACH_EXCEPTIONS
    /** The backing Mach exception server, if any. Nil if the reporter has not been enabled, or if
     * the configured signal handler type is not PLCrashReporterSignalHandlerTypeMach. */
    __strong PLCrashMachExceptionServer *_machServer;
    
    /** Previously registered Mach exception ports, if any. */
    __strong PLCrashMachExceptionPortSet *_previousMachPorts;
#endif /* PLCRASH_FEATURE_MACH_EXCEPTIONS */

    /** Application identifier */
    __strong NSString *_applicationIdentifier;

    /** Application version */
    __strong NSString *_applicationVersion;
    
    /** Application marketing version */
    __strong NSString *_applicationMarketingVersion;

    /** Path to the crash reporter internal data directory */
    __strong NSString *_crashReportDirectory;
}

+ (void) initialize {
    if (![[self class] isEqual: [PLCrashReporter class]])
        return;

    /* Enable dyld image monitoring */
    plcrash_nasync_image_list_init(&shared_image_list, mach_task_self());
    _dyld_register_func_for_add_image(image_add_callback);
    _dyld_register_func_for_remove_image(image_remove_callback);
}


/* (Deprecated) Crash reporter singleton. */
static PLCrashReporter *sharedReporter = nil;

/**
 * Return the default crash reporter instance. The returned instance will be configured
 * appropriately for release deployment.
 *
 * @deprecated As of PLCrashReporter 1.2, the default reporter instance has been deprecated, and API
 * clients should initialize a crash reporter instance directly.
 */
+ (PLCrashReporter *) sharedReporter {
    static dispatch_once_t onceLock;
    dispatch_once(&onceLock, ^{
        if (sharedReporter == nil)
            sharedReporter = [[PLCrashReporter alloc] initWithBundle: [NSBundle mainBundle] configuration: [PLCrashReporterConfig defaultConfiguration]];
    });
    return sharedReporter;
}

/**
 * Initialize a new PLCrashReporter instance with a default configuration appropraite
 * for release deployment.
 */
- (instancetype) init {
    return [self initWithConfiguration: [PLCrashReporterConfig defaultConfiguration]];
}

/**
 * Initialize a new PLCrashReporter instance with the given configuration.
 *
 * @param configuration The configuration to be used by this reporter instance.
 */
- (instancetype) initWithConfiguration: (PLCrashReporterConfig *) configuration {
    return [self initWithBundle: [NSBundle mainBundle] configuration: configuration];
}

/**
 * Returns YES if the application has previously crashed and
 * an pending crash report is available.
 */
- (BOOL) hasPendingCrashReport {
    /* Check for a live crash report file */
    return [[NSFileManager defaultManager] fileExistsAtPath: [self crashReportPath]];
}


/**
 * If an application has a pending crash report, this method returns the crash
 * report data.
 *
 * You may use this to submit the report to your own HTTP server, over e-mail, or even parse and
 * introspect the report locally using the PLCrashReport API.
 *
 * @return Returns nil if the crash report data could not be loaded.
 */
- (NSData *) loadPendingCrashReportData {
    return [self loadPendingCrashReportDataAndReturnError: NULL];
}


/**
 * If an application has a pending crash report, this method returns the crash
 * report data.
 *
 * You may use this to submit the report to your own HTTP server, over e-mail, or even parse and
 * introspect the report locally using the PLCrashReport API.
 
 * @param outError A pointer to an NSError object variable. If an error occurs, this pointer
 * will contain an error object indicating why the pending crash report could not be
 * loaded. If no error occurs, this parameter will be left unmodified. You may specify
 * nil for this parameter, and no error information will be provided.
 *
 * @return Returns nil if the crash report data could not be loaded.
 */
- (NSData *) loadPendingCrashReportDataAndReturnError: (NSError **) outError {
    /* Load the (memory mapped) data */
    return [NSData dataWithContentsOfFile: [self crashReportPath] options: NSDataReadingMappedIfSafe error: outError];
}


/**
 * Purge a pending crash report.
 *
 * @return Returns YES on success, or NO on error.
 */
- (BOOL) purgePendingCrashReport {
    return [self purgePendingCrashReportAndReturnError: NULL];
}


/**
 * Purge a pending crash report.
 *
 * @return Returns YES on success, or NO on error.
 */
- (BOOL) purgePendingCrashReportAndReturnError: (NSError **) outError {
    return [[NSFileManager defaultManager] removeItemAtPath: [self crashReportPath] error: outError];
}


/**
 * Enable the crash reporter. Once called, all application crashes will
 * result in a crash report being written prior to application exit.
 *
 * @return Returns YES on success, or NO if the crash reporter could
 * not be enabled.
 *
 * @par Registering Multiple Reporters
 *
 * Only one PLCrashReporter instance may be enabled in a process; attempting to enable an additional instance
 * will return NO, and the reporter will not be enabled. This restriction may be removed in a future release.
 */
- (BOOL) enableCrashReporter {
    return [self enableCrashReporterAndReturnError: nil];
}



/**
 * Enable the crash reporter. Once called, all application crashes will
 * result in a crash report being written prior to application exit.
 *
 * This method must only be invoked once. Further invocations will throw
 * a PLCrashReporterException.
 *
 * @param outError A pointer to an NSError object variable. If an error occurs, this pointer
 * will contain an error in the PLCrashReporterErrorDomain indicating why the Crash Reporter
 * could not be enabled. If no error occurs, this parameter will be left unmodified. You may
 * specify nil for this parameter, and no error information will be provided.
 *
 * @return Returns YES on success, or NO if the crash reporter could
 * not be enabled.
 *
 * @par Registering Multiple Reporters
 *
 * Only one PLCrashReporter instance may be enabled in a process; attempting to enable an additional instance
 * will return NO and a PLCrashReporterErrorResourceBusy error, and the reporter will not be enabled.
 * This restriction may be removed in a future release.
 */
- (BOOL) enableCrashReporterAndReturnError: (NSError **) outError {
    /* Prevent enabling more than one crash reporter, process wide. We can not support multiple chained reporters
     * due to the use of NSUncaughtExceptionHandler (it doesn't support chaining or assocation of context with the callbacks), as
     * well as our legacy approach of deregistering any signal handlers upon the first signal. Once PLCrashUncaughtExceptionHandler is
     * implemented, and we support double-fault handling without resetting the signal handlers, we can support chaining of multiple
     * crash reporters. */
    {
        static BOOL enforceOne = NO;
        pthread_mutex_t enforceOneLock = PTHREAD_MUTEX_INITIALIZER;
        pthread_mutex_lock(&enforceOneLock); {
            if (enforceOne) {
                pthread_mutex_unlock(&enforceOneLock);
                plcrash_populate_error(outError, PLCrashReporterErrorResourceBusy, @"A PLCrashReporter instance has already been enabled", nil);
                return NO;
            }
            enforceOne = YES;
        } pthread_mutex_unlock(&enforceOneLock);
    }

    /* Check for programmer error */
    if (_enabled)
        [NSException raise: PLCrashReporterException format: @"The crash reporter has already been enabled"];

    /* Create the directory tree */
    if (![self populateCrashReportDirectoryAndReturnError: outError])
        return NO;

    /* Set up the signal handler context */
    signal_handler_context.path = strdup([[self crashReportPath] UTF8String]); // NOTE: would leak if this were not a singleton struct
    assert(_applicationIdentifier != nil);
    assert(_applicationVersion != nil);
    plcrash_log_writer_init(&signal_handler_context.writer, _applicationIdentifier, _applicationVersion, _applicationMarketingVersion, [self mapToAsyncSymbolicationStrategy: _config.symbolicationStrategy], false);

    /* Set custom data, if already set before enabling */
    if (self.customData != nil) {
        plcrash_log_writer_set_custom_data(&signal_handler_context.writer, self.customData);
    }

    /* Enable the signal handler */
    switch (_config.signalHandlerType) {
        case PLCrashReporterSignalHandlerTypeBSD:
            for (size_t i = 0; i < monitored_signals_count; i++) {
                if (![[PLCrashSignalHandler sharedHandler] registerHandlerForSignal: monitored_signals[i] callback: &signal_handler_callback context: &signal_handler_context error: outError])
                    return NO;
            }
            break;

#if PLCRASH_FEATURE_MACH_EXCEPTIONS
        case PLCrashReporterSignalHandlerTypeMach: {
            /* We still need to use signal handlers to catch SIGABRT in-process. The kernel sends an EXC_CRASH mach exception
             * to denote SIGABRT termination. In that case, catching the Mach exception in-process leads to process deadlock
             * in an uninterruptable wait. Thus, we fall back on BSD signal handlers for SIGABRT, and do not register for
             * EXC_CRASH. */
            if (![[PLCrashSignalHandler sharedHandler] registerHandlerForSignal: SIGABRT callback: &signal_handler_callback context: &signal_handler_context error: outError])
                return NO;
            
            /* Enable the server. */
            _machServer = [self enableMachExceptionServerWithPreviousPortSet:  &_previousMachPorts
                                                                    callback: &mach_exception_callback
                                                                     context: &signal_handler_context
                                                                       error: outError];
            if (_machServer == nil)
                return NO;
            
            /*
             * MEMORY WARNING: To ensure that our instance survives for the lifetime of the callback registration,
             * we keep a reference on self. This is necessary to ensure that the Mach exception server instance and previous port set
             * survive for the lifetime of the callback. Since there's currently no support for *deregistering* a crash reporter,
             * this simply results in the reporter living forever.
             */
            CFBridgingRetain(self);
            
            /*
             * Save the previous ports. There's a race condition here, in that an exception that is delivered before (or during)
             * setting the previous port values will see a fully and/or partially configured port set. This could be an issue
             * when interoperating with managed runtimes, where NULL dereferences may trigger exception handling
             * in a common runtime case.
             *
             * TODO: Investigate use of (async-safe) locking to close the window in which an exception would not be safely forwarded.
             * This issue also exists (and is noted with a TODO) in PLCrashSignalHandler.
             */
            signal_handler_context.port_set = [_previousMachPorts asyncSafeRepresentation];
            break;
        }
#endif /* PLCRASH_FEATURE_MACH_EXCEPTIONS */
    }

    /* Set the uncaught exception handler */
    if(_config.shouldRegisterUncaughtExceptionHandler) {
      NSSetUncaughtExceptionHandler(&uncaught_exception_handler);
    }
  
    /* Success */
    _enabled = YES;
    return YES;
}

/**
 * Generate a live crash report for a given @a thread, without triggering an actual crash condition.
 * This may be used to log current process state without actually crashing. The crash report data will be
 * returned on success.
 *
 * @param thread The thread which will be marked as the failing thread in the generated report.
 *
 * @return Returns nil if the crash report data could not be generated.
 *
 * @sa PLCrashReporter::generateLiveReportWithThread:exception:error:
 */
- (NSData *) generateLiveReportWithThread: (thread_t) thread {
    return [self generateLiveReportWithThread: thread error: NULL];
}

/**
 * Generate a live crash report for a given @a thread, without triggering an actual crash condition.
 * This may be used to log current process state without actually crashing. The crash report data will be
 * returned on success.
 *
 * @param thread The thread which will be marked as the failing thread in the generated report.
 * @param outError A pointer to an NSError object variable. If an error occurs, this pointer
 * will contain an error object indicating why the crash report could not be generated or loaded. If no
 * error occurs, this parameter will be left unmodified. You may specify nil for this parameter, and no
 * error information will be provided.
 *
 * @return Returns nil if the crash report data could not be loaded.
 *
 * @sa PLCrashReporter::generateLiveReportWithThread:exception:error:
 */
- (NSData *) generateLiveReportWithThread: (thread_t) thread error: (NSError **) outError {
    return [self generateLiveReportWithThread: thread exception: nil error: outError];
}


/* State and callback used by -generateLiveReportWithThread */
struct plcr_live_report_context {
    plcrash_log_writer_t *writer;
    plcrash_async_file_t *file;
    plcrash_log_signal_info_t *info;
};
static plcrash_error_t plcr_live_report_callback (plcrash_async_thread_state_t *state, void *ctx) {
    struct plcr_live_report_context *plcr_ctx = ctx;
    return plcrash_log_writer_write(plcr_ctx->writer, pl_mach_thread_self(), &shared_image_list, plcr_ctx->file, plcr_ctx->info, state);
}


/**
 * Generate a live crash report for a given @a thread, without triggering an actual crash condition.
 * This may be used to log current process state without actually crashing. The crash report data will be
 * returned on success.
 *
 * @param thread The thread which will be marked as the failing thread in the generated report.
 * @param exception An exception to be included as the report's uncaught exception, or nil.
 * @param outError A pointer to an NSError object variable. If an error occurs, this pointer
 * will contain an error object indicating why the crash report could not be generated or loaded. If no
 * error occurs, this parameter will be left unmodified. You may specify nil for this parameter, and no
 * error information will be provided.
 *
 * @return Returns nil if the crash report data could not be loaded.
 *
 * @todo Implement in-memory, rather than requiring writing of the report to disk.
 */
- (NSData *) generateLiveReportWithThread: (thread_t) thread exception: (NSException *) exception error: (NSError **) outError {
    plcrash_log_writer_t writer;
    plcrash_async_file_t file;
    plcrash_error_t err;

    /* Open the output file */
    NSString *templateStr = [NSTemporaryDirectory() stringByAppendingPathComponent: @"live_crash_report.XXXXXX"];
    char *path = strdup([templateStr fileSystemRepresentation]);
    
    int fd = mkstemp(path);
    if (fd < 0) {
        plcrash_populate_posix_error(outError, errno, NSLocalizedString(@"Failed to create temporary path", @"Error opening temporary output path"));
        free(path);

        return nil;
    }

    /* Initialize the output context */
    plcrash_log_writer_init(&writer, _applicationIdentifier, _applicationVersion, _applicationMarketingVersion, [self mapToAsyncSymbolicationStrategy: _config.symbolicationStrategy], true);
    plcrash_async_file_init(&file, fd, _config.maxReportBytes);

    /* Set custom data, if already set before enabling */
    if (self.customData != nil) {
        plcrash_log_writer_set_custom_data(&writer, self.customData);
    }
    
    if (exception != nil)
        plcrash_log_writer_set_exception(&writer, exception);
    
    /* Mock up a SIGTRAP-based signal info */
    plcrash_log_bsd_signal_info_t bsd_signal_info;
    plcrash_log_signal_info_t signal_info;
    bsd_signal_info.signo = SIGTRAP;
    bsd_signal_info.code = TRAP_TRACE;
    bsd_signal_info.address = __builtin_return_address(0);

    signal_info.bsd_info = &bsd_signal_info;
    signal_info.mach_info = NULL;
    
    /* Write the crash log using the already-initialized writer */
    if (thread == pl_mach_thread_self()) {
        struct plcr_live_report_context ctx = {
            .writer = &writer,
            .file = &file,
            .info = &signal_info
        };
        err = plcrash_async_thread_state_current(plcr_live_report_callback, &ctx);
    } else {
        err = plcrash_log_writer_write(&writer, thread, &shared_image_list, &file, &signal_info, NULL);
    }
    plcrash_log_writer_close(&writer);

    /* Flush the data */
    plcrash_async_file_flush(&file);
    plcrash_async_file_close(&file);

    /* Check for write failure */
    NSData *data;
    if (err != PLCRASH_ESUCCESS) {
        PLCR_LOG("Write failed with error %s", plcrash_async_strerror(err));
        plcrash_populate_error(outError, PLCrashReporterErrorUnknown, @"Failed to write the crash report to disk", nil);
        data = nil;
        goto cleanup;
    }

    data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String: path]
                                  options:NSDataReadingMappedAlways | NSDataReadingUncached
                                    error:outError];
    if (data == nil) {
        /* This should only happen if our data is deleted out from under us */
        plcrash_populate_error(outError, PLCrashReporterErrorUnknown, NSLocalizedString(@"Unable to open live crash report for reading", nil), nil);
        goto cleanup;
    }

cleanup:
    /* Finished -- clean up. */
    plcrash_log_writer_free(&writer);

    if (unlink(path) != 0) {
        /* This shouldn't fail, but if it does, there's no use in returning nil */
        PLCR_LOG("Failure occured deleting live crash report: %s", strerror(errno));
    }

    free(path);
    return data;
}


/**
 * Generate a live crash report, without triggering an actual crash condition. This may be used to log
 * current process state without actually crashing. The crash report data will be returned on
 * success.
 * 
 * @return Returns nil if the crash report data could not be loaded.
 */
- (NSData *) generateLiveReport {
    return [self generateLiveReportAndReturnError: NULL];
}


/**
 * Generate a live crash report for the current thread, without triggering an actual crash condition.
 * This may be used to log current process state without actually crashing. The crash report data will be
 * returned on success.
 *
 * @param outError A pointer to an NSError object variable. If an error occurs, this pointer
 * will contain an error object indicating why the pending crash report could not be
 * generated or loaded. If no error occurs, this parameter will be left unmodified. You may specify
 * nil for this parameter, and no error information will be provided.
 * 
 * @return Returns nil if the crash report data could not be loaded.
 */
- (NSData *) generateLiveReportAndReturnError: (NSError **) outError {
    return [self generateLiveReportWithException: nil error: outError];
}


- (NSData *) generateLiveReportWithException: (NSException *)exception error: (NSError **) outError {
    return [self generateLiveReportWithThread: pl_mach_thread_self() exception: exception error: outError];
}

/**
 * Set the callbacks that will be executed by the receiver after a crash has occured and been recorded by PLCrashReporter.
 *
 * @param callbacks A pointer to an initialized PLCrashReporterCallbacks structure.
 *
 * @note This method must be called prior to PLCrashReporter::enableCrashReporter or
 * PLCrashReporter::enableCrashReporterAndReturnError:
 *
 * @sa The @ref async_safety documentation.
 */
- (void) setCrashCallbacks: (PLCrashReporterCallbacks *) callbacks {
    /* Check for programmer error; this should not be called after the signal handler is enabled as to ensure that
     * the signal handler can never fire with a partially initialized callback structure. */
    if (_enabled)
        [NSException raise: PLCrashReporterException format: @"The crash reporter has already been enabled"];

    assert(callbacks->version == 0);

    /* Re-initialize our internal callback structure */
    crashCallbacks.version = 0;

    /* Re-configure the saved callbacks */
    crashCallbacks.context = callbacks->context;
    crashCallbacks.handleSignal = callbacks->handleSignal;
}

/**
 * Set the custom data that will be saved in the crash report along the rest of information,
 * It deletes any previous custom data configured.
 *
 * @param customData A string with the custom data to save.
 */
- (void) setCustomData: (NSData *) customData {
    _customData = customData;
    plcrash_log_writer_set_custom_data(&signal_handler_context.writer, customData);
}

- (NSString *) crashReportPath {
    return [[self crashReportDirectory] stringByAppendingPathComponent: PLCRASH_LIVE_CRASHREPORT];
}

@end

/**
 * @internal
 *
 * Private Methods
 */
@implementation PLCrashReporter (PrivateMethods)

/**
 * @internal
 *
 * This is the designated initializer, but it is not intended
 * to be called externally.
 *
 * @param applicationIdentifier The application identifier to be included in crash reports.
 * @param applicationVersion The application version number to be included in crash reports.
 * @param applicationMarketingVersion The application marketing version number to be included in crash reports.
 * @param configuration The PLCrashReporter configuration.
 *
 * @todo The appId and version values should be fetched from the PLCrashReporterConfig, once the API
 * has been extended to allow supplying these values.
 */
- (id) initWithApplicationIdentifier: (NSString *) applicationIdentifier appVersion: (NSString *) applicationVersion appMarketingVersion: (NSString *) applicationMarketingVersion configuration: (PLCrashReporterConfig *) configuration {
    /* Initialize our superclass */
    if ((self = [super init]) == nil)
        return nil;

    /* Save the configuration */
    _config = configuration;
    _applicationIdentifier = applicationIdentifier;
    _applicationVersion = applicationVersion;
    _applicationMarketingVersion = applicationMarketingVersion;
    
    /* No occurances of '/' should ever be in a bundle ID, but just to be safe, we escape them */
    NSString *appIdPath = [applicationIdentifier stringByReplacingOccurrencesOfString: @"/" withString: @"_"];
    
    NSString *basePath = _config.basePath;
    if (basePath == nil) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        basePath = [paths objectAtIndex: 0];
    }
    _crashReportDirectory = basePath;
    return self;
}


/**
 * @internal
 *
 * Derive the bundle identifier and version from @a bundle.
 *
 * @param bundle The application's main bundle.
 * @param configuration The PLCrashReporter configuration to use for this instance.
 */
- (id) initWithBundle: (NSBundle *) bundle configuration: (PLCrashReporterConfig *) configuration {
    NSString *bundleIdentifier = [bundle bundleIdentifier];
    NSString *bundleVersion = [[bundle infoDictionary] objectForKey: (NSString *) kCFBundleVersionKey];
    NSString *bundleMarketingVersion = [[bundle infoDictionary] objectForKey: @"CFBundleShortVersionString"];
    
    /* Verify that the identifier is available */
    if (bundleIdentifier == nil) {
        const char *progname = getprogname();
        if (progname == NULL) {
            [NSException raise: PLCrashReporterException format: @"Can not determine process identifier or process name"];
            return nil;
        }

        PLCR_LOG("Warning -- bundle identifier, using process name %s", progname);
        bundleIdentifier = [NSString stringWithUTF8String: progname];
    }

    /* Verify that the version is available */
    if (bundleVersion == nil) {
        PLCR_LOG("Warning -- bundle version unavailable");
        bundleVersion = @"";
    }

    return [self initWithApplicationIdentifier: bundleIdentifier appVersion: bundleVersion appMarketingVersion:bundleMarketingVersion configuration: configuration];
}

#if PLCRASH_FEATURE_MACH_EXCEPTIONS

/**
 * Create, register, and return a Mach exception server.
 *
 * @param[out] previousPortSet The previously registered Mach exception ports.
 * @param context The context to be provided to the callback.
 * @param outError A pointer to an NSError object variable. If an error occurs, this pointer
 * will contain an error in the PLCrashReporterErrorDomain indicating why the Crash Reporter
 * could not be enabled. If no error occurs, this parameter will be left unmodified. You may
 * specify nil for this parameter, and no error information will be provided.
 */
- (PLCrashMachExceptionServer *) enableMachExceptionServerWithPreviousPortSet: (__strong PLCrashMachExceptionPortSet **) previousPortSet
                                                                     callback: (PLCrashMachExceptionHandlerCallback) callback
                                                                      context: (void *) context
                                                                        error: (NSError **) outError
{
    /* Determine the target exception type mask. Note that unlike some other Mach exception-based
     * crash reporting implementations, we do not monitor EXC_RESOURCE:
     *
     * EXC_RESOURCE wasn't added until iOS 5.1 and Mac OS X 10.8, and is used for
     * kernel-based thread resource constraints on a per-thread/per-task basis. XNU
     * supports either pausing threads that exceed the defined constraints (via the private
     * ledger kernel APIs), or issueing a Mach exception that can be used to monitor the
     * constraints.
     *
     * The EXC_RESOURCE resouce exception is used, for example, to implement the
     * private posix_spawnattr_setcpumonitor() API, which allows for monitoring CPU utilization
     * by observing issued EXC_RESOURCE exceptions. This appears to be used by launchd.
     *
     * Either way, we're uninterested in EXC_RESOURCE; the xnu ux_exception() handler should not deliver
     * a signal for the exception and should return KERN_SUCCESS, letting exception_triage()
     * consider it as handled.
     */
    exception_mask_t exc_mask = EXC_MASK_BAD_ACCESS |       /* Memory access fail */
                                EXC_MASK_BAD_INSTRUCTION |  /* Illegal instruction */
                                EXC_MASK_ARITHMETIC |       /* Arithmetic exception (eg, divide by zero) */
                                EXC_MASK_SOFTWARE |         /* Software exception (eg, as triggered by x86's bound instruction) */
                                EXC_MASK_BREAKPOINT;        /* Trace or breakpoint */
    
    /* EXC_GUARD was added in xnu 13.x (iOS 6.0, Mac OS X 10.9) */
#ifdef EXC_MASK_GUARD
    PLCrashHostInfo *hinfo = [PLCrashHostInfo currentHostInfo];
    
    if (hinfo != nil && hinfo.darwinVersion.major >= 13)
        exc_mask |= EXC_MASK_GUARD; /* Process accessed a guarded file descriptor. See also: https://devforums.apple.com/message/713907#713907 */
#endif
    
    /* Create the server */
    NSError *osError;
    PLCrashMachExceptionServer *server = [[PLCrashMachExceptionServer alloc] initWithCallBack: callback context: context error: &osError];
    if (server == nil) {
        plcrash_populate_error(outError, PLCrashReporterErrorOperatingSystem, @"Failed to instantiate the Mach exception server.", osError);
        return nil;
    }
    
    /* Allocate the port */
    PLCrashMachExceptionPort *port = [server exceptionPortWithMask: exc_mask error: &osError];
    if (port == nil) {
        plcrash_populate_error(outError, PLCrashReporterErrorOperatingSystem, @"Failed to instantiate the Mach exception port.", osError);
        return nil;
    }
    
    /* Register for the task */
    if (![port registerForTask: mach_task_self() previousPortSet: previousPortSet error: &osError]) {
        plcrash_populate_error(outError, PLCrashReporterErrorOperatingSystem, @"Failed to set the target task's mach exception ports.", osError);
        return nil;
    }

    return server;
}

#endif /* PLCRASH_FEATURE_MACH_EXCEPTIONS */


/**
 * Map the configuration defined @a strategy to the backing plcrash_async_symbol_strategy_t representation.
 *
 * @param strategy The strategy value to map.
 */
- (plcrash_async_symbol_strategy_t) mapToAsyncSymbolicationStrategy: (PLCrashReporterSymbolicationStrategy) strategy {
    plcrash_async_symbol_strategy_t result = PLCRASH_ASYNC_SYMBOL_STRATEGY_NONE;
    
    if (strategy == PLCrashReporterSymbolicationStrategyNone)
        return PLCRASH_ASYNC_SYMBOL_STRATEGY_NONE;
    
    if (strategy & PLCrashReporterSymbolicationStrategySymbolTable)
        result |= PLCRASH_ASYNC_SYMBOL_STRATEGY_SYMBOL_TABLE;
    
    if (strategy & PLCrashReporterSymbolicationStrategyObjC)
        result |= PLCRASH_ASYNC_SYMBOL_STRATEGY_OBJC;
    
    return result;
}

/**
 * Validate (and create if necessary) the crash reporter directory structure.
 */
- (BOOL) populateCrashReportDirectoryAndReturnError: (NSError **) outError {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    /* Set up reasonable directory attributes */
    NSDictionary *attributes = [NSDictionary dictionaryWithObject: [NSNumber numberWithUnsignedLong: 0755] forKey: NSFilePosixPermissions];
    
    /* Create the top-level path */
    if (![fm fileExistsAtPath: [self crashReportDirectory]] &&
        ![fm createDirectoryAtPath: [self crashReportDirectory] withIntermediateDirectories: YES attributes: attributes error: outError])
    {
        return NO;
    }

    /* Create the queued crash report directory */
    if (![fm fileExistsAtPath: [self queuedCrashReportDirectory]] &&
        ![fm createDirectoryAtPath: [self queuedCrashReportDirectory] withIntermediateDirectories: YES attributes: attributes error: outError])
    {
        return NO;
    }

    return YES;
}

/**
 * Return the path to the crash reporter data directory.
 */
- (NSString *) crashReportDirectory {
    return _crashReportDirectory;
}


/**
 * Return the path to to-be-sent crash reports.
 */
- (NSString *) queuedCrashReportDirectory {
    return [[self crashReportDirectory] stringByAppendingPathComponent: PLCRASH_QUEUED_DIR];
}

@end
