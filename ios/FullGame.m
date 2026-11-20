#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import "SteamInstaller.h"
#import "SteamSignInBridge.h"
#import "TouchOverlay.h"
#include <dlfcn.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <poll.h>
#include <ifaddrs.h>
#include <sys/stat.h>

static NSDictionary<NSString *,NSString *> *AllModes(void) {
    return @{@"sps":@"Campaign", @"mps":@"Multiplayer", @"zms":@"Zombies"};
}

static NSDictionary<NSString *,NSString *> *Modes(void) {
    static NSDictionary *built;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *found = [NSMutableDictionary new];
        [AllModes() enumerateKeysAndObjectsUsingBlock:^(NSString *mode, NSString *name, BOOL *stop) {
            NSURL *sections = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:
                [NSString stringWithFormat:@"Modes/%@/pe_sections.bin", mode]];
            if ([sections checkResourceIsReachableAndReturnError:nil]) found[mode] = name;
        }];
        built = found;
    });
    return built;
}

static NSDictionary *ServerInfo(const void *bytes, size_t length, NSString *nonce) {
    if (length<4 || memcmp(bytes,"\xff\xff\xff\xff",4)) return nil;
    NSString *reply=[[NSString alloc] initWithBytes:(const char *)bytes+4 length:length-4 encoding:NSISOLatin1StringEncoding];
    NSArray *fields=[reply componentsSeparatedByString:@"\\"];
    if (![fields.firstObject hasPrefix:@"infoResponse"]) return nil;
    NSMutableDictionary *info=[NSMutableDictionary new];
    for (NSUInteger j=1; j+1<fields.count; j+=2) info[fields[j]]=fields[j+1];
    return [info[@"challenge"] isEqual:nonce] ? info : nil;
}

static NSDictionary *WiredServerInfo(uint16_t port, NSString *nonce) {
    int listener=socket(AF_INET,SOCK_STREAM,0);
    if (listener <0) return nil;
    int one=1;
    setsockopt(listener,SOL_SOCKET,SO_REUSEADDR, &one,sizeof(one));
    struct sockaddr_in local={.sin_len=sizeof(local),.sin_family=AF_INET,
        .sin_port=htons(19469),.sin_addr={htonl(INADDR_LOOPBACK)}};
    struct pollfd pfd={.fd=listener ,.events=POLLIN};
    int client=-1;
    if (!bind(listener,(struct sockaddr *) &local,sizeof(local)) && !listen(listener,1) && poll(&pfd,1,10000) >0)
        client=accept(listener,NULL,NULL);
    close(listener);
    if (client <0) return nil;
    struct timeval timeout={.tv_sec=3};
    setsockopt(client,SOL_SOCKET,SO_RCVTIMEO, &timeout,sizeof(timeout));
    setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE, &one,sizeof(one));
    NSData *request=[[NSString stringWithFormat:@"%u %@\n",(unsigned)port,nonce] dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *reply=[NSMutableData new];
    if (send(client,request.bytes,request.length,0)==(ssize_t)request.length ) {
        char buffer[2048];
        while (reply.length <8192) {
            ssize_t n=recv(client,buffer,sizeof(buffer),0);
            if (n <=0) break;
            [reply appendBytes:buffer length:n];
        }
    }
    close(client);
    return ServerInfo(reply.bytes,reply.length,nonce);
}

static NSTimeInterval Delay(NSString *key, NSTimeInterval fallback) {
    double value=[NSUserDefaults.standardUserDefaults doubleForKey:key];
    return value>=5 && value<=600 ? value : fallback;
}

static uint32_t ClientState(void *handle, BOOL mp) {
    uint8_t **arena=dlsym(handle,"bo2_g_base");
    const uint8_t *base=arena ? *arena : NULL;
    if (!base) return UINT32_MAX;
    uint32_t value; memcpy(&value,base+(mp?0x10e9d88:0x10e7e18),sizeof(value));
    return value;
}

static void QueueConnect(void *handle, void (*queue)(const char *), NSString *command, BOOL mp, unsigned retries) {
    uint32_t before=ClientState(handle,mp);
    queue(command.UTF8String);
    if (!retries || before==UINT32_MAX) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (ClientState(handle,mp)!=before) return;
        NSLog(@"Private connect left the client state at %u, retrying",before);
        QueueConnect(handle,queue,command,mp,retries-1);
    });
}

static void ConfigureRuntime(NSString *mode) {
    if (UIScreen.mainScreen.maximumFramesPerSecond > 60) setenv("BO2_PUMP_US", "1000", 1);
    NSDictionary *settings = @{
        @"BO2_WINDOW":@"1", @"BO2_WINDOW_HOLD":@"0", @"BO2_STALL_ABORT":@"0",
        @"BO2_MAX_IMPORTS":@"0", @"BO2_TR_CACHE":@"0", @"BO2_MUTE":@"0", @"BO2_XAUDIO":@"1",
        @"BO2_DEPTH_BIAS":@"1", @"BO2_DEPTH_DSV":@"1", @"BO2_SV_INLINE":@"1",
        @"BO2_NO_FORCE_MAP":@"1", @"BO2_MSGB":@"150", @"BO2_VB_RESIDENT":@"1",
        @"BO2_VPX_NATIVE":@"1", @"BO2_VPX_REPLACE":@"1", @"BO2_W32_FAST":@"1",
        @"BO2_PREEMPT_W":@"20000", @"BO2_CS_COOP":@"1", @"BO2_RR_FAIR":@"1",
        @"BO2_REAL_MUTEX":@"1", @"BO2_HOST_THREADS":@"jq,snd,snddec,srv,backend", @"BO2_HW_ATOMICS":@"2"
    };
    for (NSString *key in settings) setenv(key.UTF8String, [settings[key] UTF8String], 1);
    if ([mode isEqualToString:@"sps"]) {
        setenv("BO2_MIP_CIBLES", "0", 1);
    } else {
        setenv("BO2_SHADER_CREE", "1", 1);
        setenv("BO2_FFOTD_TU", [mode isEqualToString:@"zms"] ? "13" : "17", 1);
    }
}

static NSURL *GameDirectory(NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *assets = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Game"];
    NSURL *support = [files URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                          appropriateForURL:nil create:YES error:error];
    if (!support) return nil;
    if (![assets checkResourceIsReachableAndReturnError:nil]) {
        assets = [support URLByAppendingPathComponent:@"BO2GameFiles"];
        if (![assets checkResourceIsReachableAndReturnError:nil]) {
            if (error) *error = [NSError errorWithDomain:@"BO2" code:1 userInfo:@{
                NSLocalizedDescriptionKey:@"Sign in to Steam, then tap Game Files to download your game."
            }];
            return nil;
        }
    }
    NSArray<NSURL *> *entries = [files contentsOfDirectoryAtURL:assets includingPropertiesForKeys:nil options:0 error:error];
    if (!entries) return nil;
    NSURL *root = [support URLByAppendingPathComponent:@"BO2"];
    if (![files createDirectoryAtURL:[root URLByAppendingPathComponent:@"players"] withIntermediateDirectories:YES
                          attributes:nil error:error]) return nil;
    for (NSURL *entry in entries) {
        if ([entry.lastPathComponent.lowercaseString isEqualToString:@"players"]) continue;
        NSURL *link = [root URLByAppendingPathComponent:entry.lastPathComponent];
        NSString *old = [files destinationOfSymbolicLinkAtPath:link.path error:nil];
        if ([old isEqualToString:entry.path]) continue;
        if (old && ![files removeItemAtURL:link error:error]) return nil;
        if (![files createSymbolicLinkAtURL:link withDestinationURL:entry error:error]) return nil;
    }
    return root;
}

static UIButton *Card(NSString *title, NSString *subtitle, NSString *symbol) {
    UIButtonConfiguration *look = UIButtonConfiguration.filledButtonConfiguration;
    look.title = title;
    look.subtitle = subtitle;
    look.image = [UIImage systemImageNamed:symbol];
    look.imagePlacement = NSDirectionalRectEdgeTop;
    look.imagePadding = 14;
    look.titlePadding = 4;
    look.titleAlignment = UIButtonConfigurationTitleAlignmentCenter;
    look.preferredSymbolConfigurationForImage =
        [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightSemibold];
    look.baseBackgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
    look.baseForegroundColor = UIColor.whiteColor;
    look.background.cornerRadius = 18;
    look.background.strokeColor = [UIColor colorWithWhite:1 alpha:0.14];
    look.background.strokeWidth = 1;
    look.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
        return result;
    };
    look.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSForegroundColorAttributeName] = [UIColor colorWithWhite:1 alpha:0.6];
        return result;
    };
    return [UIButton buttonWithConfiguration:look primaryAction:nil];
}

static UIButtonConfiguration *ChipLook(NSString *title, NSString *symbol, UIColor *tint) {
    UIButtonConfiguration *look = UIButtonConfiguration.filledButtonConfiguration;
    look.title = title;
    look.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    look.imagePadding = 8;
    look.preferredSymbolConfigurationForImage =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    look.baseBackgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
    look.baseForegroundColor = tint ?: [UIColor colorWithWhite:1 alpha:0.9];
    look.background.cornerRadius = 12;
    look.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        return result;
    };
    return look;
}

static UIButton *Chip(NSString *title, NSString *symbol) {
    return [UIButton buttonWithConfiguration:ChipLook(title, symbol, nil) primaryAction:nil];
}

static NSURL *RunFile(NSString *name) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:name];
}

static BOOL PreviousRunFailed(void) {
    return [RunFile(@"run-active") checkResourceIsReachableAndReturnError:nil];
}

static BOOL gRunning;

static void MarkRun(BOOL active) {
    if (active) [NSFileManager.defaultManager createFileAtPath:RunFile(@"run-active").path contents:nil attributes:nil];
    else [NSFileManager.defaultManager removeItemAtURL:RunFile(@"run-active") error:nil];
}

static void BeginRunLog(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    gRunning = YES;
    MarkRun(YES);
    struct stat out, null;
    if (fstat(STDERR_FILENO, &out) || stat("/dev/null", &null) || !S_ISCHR(out.st_mode) || out.st_rdev != null.st_rdev) return;
    NSURL *log = RunFile(@"last-run.log"), *previous = RunFile(@"previous-run.log");
    [files removeItemAtURL:previous error:nil];
    [files moveItemAtURL:log toURL:previous error:nil];
    if (!freopen(log.fileSystemRepresentation, "w", stderr)) return;
    setvbuf(stderr, NULL, _IOFBF, 1 << 16);
    static dispatch_source_t flusher;
    flusher = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(flusher, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(flusher, ^{ fflush(stderr); });
    dispatch_resume(flusher);
}

static void LogDeviceState(void) {
    NSProcessInfo *info = NSProcessInfo.processInfo;
    fprintf(stderr, "[device] thermal=%ld lowPower=%d recording=%d\n", (long)info.thermalState,
            info.lowPowerModeEnabled, UIScreen.mainScreen.isCaptured);
}

static void EndRunLog(void) {
    fflush(stderr);
    gRunning = NO;
    MarkRun(NO);
}

@interface ModePicker : UIViewController
@end

@implementation ModePicker {
    UIStackView *_menu;
    UILabel *_status;
    SteamInstaller *_installer;
    UIButton *_steamAccount;
    BO2SteamLaunch *_steamLaunch;
    BOOL _onlineRequested;
    BOOL _started;
    BOOL _checking;
    NSString *_server;
    uint16_t _port;
    BOOL _wired;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.045 blue:0.055 alpha:1];
    UILabel *title = [UILabel new];
    title.attributedText = [[NSAttributedString alloc] initWithString:@"BLACK OPS II" attributes:@{
        NSKernAttributeName:@3, NSForegroundColorAttributeName:UIColor.whiteColor,
        NSFontAttributeName:[UIFont systemFontOfSize:26 weight:UIFontWeightHeavy]}];
    _steamAccount = Chip(nil, nil);
    _steamAccount.accessibilityIdentifier = @"steam-account";
    [_steamAccount addTarget:self action:@selector(steamAccount) forControlEvents:UIControlEventTouchUpInside];
    [_steamAccount setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, _steamAccount]];
    header.alignment = UIStackViewAlignmentCenter;
    UIStackView *modes = [UIStackView new];
    modes.distribution = UIStackViewDistributionFillEqually;
    modes.spacing = 12;
    NSDictionary *detail = @{@"sps":@[@"Story missions", @"flag.fill"],
                             @"mps":@[@"Online with Steam or local", @"person.3.fill"],
                             @"zms":@[@"Online with Steam or solo", @"bolt.heart.fill"]};
    for (NSString *mode in @[@"sps",@"mps",@"zms"]) {
        if (!Modes()[mode]) continue;
        UIButton *card = Card(Modes()[mode], detail[mode][0], detail[mode][1]);
        card.accessibilityIdentifier = mode;
        [card addTarget:self action:@selector(choose:) forControlEvents:UIControlEventTouchUpInside];
        [modes addArrangedSubview:card];
    }
    UIButton *join = Chip(@"Join Private Server", @"network");
    [join addTarget:self action:@selector(pickServer) forControlEvents:UIControlEventTouchUpInside];
    UIButton *library = Chip(@"Steam Library", @"square.grid.2x2.fill");
    library.accessibilityIdentifier = @"steam-library";
    [library addTarget:self action:@selector(steamLibrary) forControlEvents:UIControlEventTouchUpInside];
    UIButton *files = Chip(@"Game Files", @"arrow.down.circle.fill");
    [files addTarget:self action:@selector(steamInstall) forControlEvents:UIControlEventTouchUpInside];
    UIButton *fpsLog = Chip(@"Share FPS log", @"square.and.arrow.up");
    [fpsLog addTarget:self action:@selector(shareFPSLog:) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *tools = [[UIStackView alloc] initWithArrangedSubviews:@[join, library, files, fpsLog]];
    tools.distribution = UIStackViewDistributionFillEqually;
    tools.spacing = 12;
    _status = [UILabel new];
    _status.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    _status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 2;
    _menu = [[UIStackView alloc] initWithArrangedSubviews:@[header, modes, tools, _status]];
    _menu.axis = UILayoutConstraintAxisVertical;
    _menu.spacing = 12;
    _menu.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_menu];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_menu.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_menu.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [_menu.topAnchor constraintEqualToAnchor:safe.topAnchor constant:14],
        [_menu.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
        [header.heightAnchor constraintEqualToConstant:40],
        [tools.heightAnchor constraintEqualToConstant:44],
        [_status.heightAnchor constraintEqualToConstant:32]
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateSteamAccount:)
                                             name:@"BO2SteamSignInDidChange" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(steamLibraryPlay:)
                                             name:@"BO2SteamLibraryPlay" object:nil];
    [self updateSteamAccount:nil];
    if (PreviousRunFailed()) _status.text = @"The last session ended unexpectedly. Its log was kept for review.";
}

- (void)shareFPSLog:(UIButton *)sender {
    NSURL *file = RunFile(@"BO2-FPS.txt");
    NSURL *raw = RunFile(@"last-run.log");
    if (![raw checkResourceIsReachableAndReturnError:nil]) {
        _status.text = @"Start a game first to record frame rates.";
        return;
    }
    sender.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        FILE *input = fopen(raw.fileSystemRepresentation, "r");
        NSMutableString *report = [NSMutableString string];
        char *line = NULL;
        size_t capacity = 0;
        BOOL zombies = NO;
        unsigned long long lastReady = 0;
        while (input && getline(&line, &capacity, input) >= 0) {
            double secs, ticks, target;
            unsigned submitted, fresh, displayed, displayedFresh, dropped;
            int hz, power, thermal, friction;
            char build[32], mode[8];
            unsigned long long frame;
            double interval, wait, encode, total;
            int userLimit, modeLimit, picked, calls, rx, ry, ox, oy, lt;
            if (sscanf(line, "[fps-session] build=%31[0-9.] mode=%7[a-z]", build, mode) == 2) {
                zombies = strcmp(mode, "zms") == 0;
                lastReady = 0;
                [report appendFormat:@"build=%s mode=%s\n", build, mode];
            } else if (sscanf(line, "[frame-ready] %llu %lf", &frame, &interval) == 2) {
                lastReady = frame;
                [report appendFormat:@"ready=%llu intervalMs=%.3f\n", frame, interval];
            } else if (sscanf(line, "[pace] %llu %d %d %d %d %lf", &frame, &userLimit, &modeLimit, &picked, &calls, &wait) == 6)
                [report appendFormat:@"engineFrame=%llu comMaxFPS=%d modeLimit=%d pickedFPS=%d waitCalls=%d limiterWaitMs=%.3f lastReady=%llu\n",
                 frame, userLimit, modeLimit, picked, calls, wait, lastReady];
            else if (sscanf(line, "[assist-range] %llu %d %lf %lf", &frame, &friction, &wait, &interval) == 4)
                [report appendFormat:@"assistTimeMs=%llu targetSource=%@ forwardUnits=%.1f angularOffsetRatio=%.5f lastReady=%llu\n",
                 frame, friction ? @"native" : @"crosshair", wait, interval, lastReady];
            else if (sscanf(line, "[stick] %llu %d %d %d %d %d %d", &frame, &rx, &ry, &ox, &oy, &friction, &lt) == 7)
                [report appendFormat:@"stickTimeMs=%llu rawX=%d rawY=%d assistedX=%d assistedY=%d active=%d leftTrigger=%d lastReady=%llu\n",
                 frame, rx, ry, ox, oy, friction, lt, lastReady];
            else if (sscanf(line, "[pad-friction] active=%d", &friction) == 1)
                [report appendFormat:@"controllerAssistActive=%d\n", friction];
            else if (strncmp(line, "[frame-prep]  ", 13) == 0) {
                double span, draw, record, lock, publish, device;
                unsigned long long drawCalls, recordCalls;
                if (sscanf(line, "[frame-prep] %llu %lf %lf %lf %lf %lf %lf %llu %llu",
                           &frame, &span, &draw, &record, &lock, &publish, &device, &drawCalls, &recordCalls) == 9)
                    [report appendFormat:@"prepFrame=%llu drawSpanMs=%.3f drawPrepareMs=%.3f drawRecordMs=%.3f drawMutexWaitMs=%.3f publishMutexWaitMs=%.3f deviceMutexWaitMs=%.3f drawCalls=%llu recordCalls=%llu\n",
                     frame, span, draw, record, lock, publish, device, drawCalls, recordCalls];
            }
            else if (sscanf(line, "[render-pump] %llu %lf %lf %lf", &frame, &wait, &total, &encode) == 4)
                [report appendFormat:@"renderFrame=%llu mainQueueWaitMs=%.3f workerBlockedMs=%.3f metalEncodeMs=%.3f\n",
                 frame, wait, total, encode];
            else if (sscanf(line, "[frame-submit] %llu %lf %lf %lf", &frame, &wait, &encode, &total) == 4)
                [report appendFormat:@"submit=%llu pickupWaitMs=%.3f pickupToCommitMs=%.3f readyToCommitMs=%.3f\n",
                 frame, wait, encode, total];
            else if (sscanf(line, "[fps-link] max=%d callbacks=%lf target=%lf lowPower=%d thermal=%d",
                            &hz, &ticks, &target, &power, &thermal) == 5)
                [report appendFormat:@"screenMax=%d callbacksHz=%.1f targetHz=%.1f lowPower=%d thermal=%d\n",
                 hz, ticks, target, power, thermal];
            else if (sscanf(line, "[PRESENT] hote=%*f unix=%*f fen=%lfs soumis=%u soumis_neufs=%u affiches=%u affiches_neufs=%u non_affiches=%u",
                            &secs, &submitted, &fresh, &displayed, &displayedFresh, &dropped) == 6 && secs > 0)
                [report appendFormat:@"window=%.3fs submittedFPS=%.1f freshSubmittedFPS=%.1f displayedFPS=%.1f freshDisplayedFPS=%.1f dropped=%u\n",
                 secs, submitted/secs, fresh/secs, displayed/secs, displayedFresh/secs, dropped];
            else if (zombies) {
                const char *events[] = {"Adding fastfile '", "Loading fastfile '", "Loading sounds for '", "Loaded sounds for '"};
                const char *labels[] = {"queued", "loading", "sound-start", "sound-finished"};
                const char prefix[] = "[OutputDebugString] ";
                const char *msg = strncmp(line, prefix, sizeof(prefix)-1) == 0 ? line + sizeof(prefix)-1 : line;
                for (unsigned i=0; i<4; ++i) {
                    size_t len = strlen(events[i]);
                    if (strncmp(msg, events[i], len)) continue;
                    const char *name = msg + len;
                    size_t n = strspn(name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -");
                    if (n && n <= 96 && name[n] == '\'')
                        [report appendFormat:@"zmStage=%s zone=%.*s lastReady=%llu\n", labels[i], (int)n, name, lastReady];
                    break;
                }
                if (strstr(msg, "server script runtime error") || strstr(msg, "Terminal script error"))
                    [report appendFormat:@"zmStage=script-error lastReady=%llu\n", lastReady];
                if (sscanf(msg, "[GSC-RATE] frame=%llu", &frame) == 1)
                    [report appendFormat:@"zmScriptFrame=%llu lastReady=%llu\n", frame, lastReady];
            }
        }
        free(line);
        if (input) fclose(input);
        BOOL ok = report.length && [report writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
            if (!ok) { self->_status.text = @"No frame measurements found in the last run."; return; }
            [self presentFPSLog:file sender:sender];
        });
    });
}

- (void)presentFPSLog:(NSURL *)file sender:(UIButton *)sender {
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    share.popoverPresentationController.sourceView = sender;
    share.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSString *steamMode = [NSUserDefaults.standardUserDefaults stringForKey:@"BO2RequestedSteamMode"];
    if (Modes()[steamMode ?: @""] && !_started && !_checking) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"BO2RequestedSteamMode"];
        [self startSteam:steamMode];
        return;
    }
    NSString *requested = [NSUserDefaults.standardUserDefaults stringForKey:@"BO2RequestedMode"];
    if (AllModes()[requested ?: @""] && !Modes()[requested] && !_started) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"BO2RequestedMode"];
        _status.text = [NSString stringWithFormat:@"%@ is not part of this build.", AllModes()[requested]];
        return;
    }
    if (Modes()[requested ?: @""] && !_started) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"BO2RequestedMode"];
        [self start:requested];
    }
}

- (NSString *)savedAddress:(NSString *)mode {
    NSString *key = [@"BO2Server." stringByAppendingString:mode];
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:key];
    NSString *host = [NSBundle.mainBundle objectForInfoDictionaryKey:@"BO2PrivateServer"];
    return saved ?: (host.length ? [NSString stringWithFormat:@"%@:%d", host,
                                    [mode isEqualToString:@"mps"] ? 24985 : 24988] : @"");
}

- (void)pickServer {
    if (_checking || _started || _installer) return;
    UIAlertController *list = [UIAlertController alertControllerWithTitle:@"Join Private Server"
                                                                  message:nil preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *mode in @[@"mps", @"zms"]) {
        if (!Modes()[mode]) continue;
        NSString *title = [mode isEqualToString:@"mps"] ? @"Aftermath · Multiplayer" : @"TranZit · Zombies";
        [list addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            UIAlertController *edit = [UIAlertController alertControllerWithTitle:title
                                                                          message:@"Enter the private server’s IPv4 address and port."
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [edit addTextFieldWithConfigurationHandler:^(UITextField *field){
                field.text = [self savedAddress:mode];
                field.placeholder = @"address:port";
                field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
                field.autocorrectionType = UITextAutocorrectionTypeNo;
            }];
            [edit addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [edit addAction:[UIAlertAction actionWithTitle:@"Join" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                [self join:mode address:edit.textFields.firstObject.text];
            }]];
            [self presentViewController:edit animated:YES completion:nil];
        }]];
    }
    [list addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:list animated:YES completion:nil];
}

- (void)join:(NSString *)mode address:(NSString *)input {
    if (_checking || _started || _installer) return;
    NSArray<NSString *> *parts = [[input stringByTrimmingCharactersInSet:
                                   NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@":"];
    struct in_addr ip;
    NSString *portText = parts.lastObject;
    NSInteger port = portText.integerValue;
    if (parts.count != 2 || inet_pton(AF_INET, parts.firstObject.UTF8String, &ip) != 1 ||
        port < 1 || port > 65535 || ![[NSString stringWithFormat:@"%ld", (long)port] isEqual:portText]) {
        _status.text = @"Enter an IPv4 address and a port from 1 to 65535.";
        return;
    }
    _checking = YES;
    _status.text = @"Checking the private server…";
    NSLog(@"Checking private %@ server", Modes()[mode]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in peer = {.sin_len=sizeof(peer), .sin_family=AF_INET, .sin_addr=ip, .sin_port=htons((uint16_t)port)};
        NSString *nonce = NSUUID.UUID.UUIDString;
        NSMutableData *query = [NSMutableData dataWithBytes:"\xff\xff\xff\xff" length:4];
        [query appendData:[[NSString stringWithFormat:@"getinfo %@", nonce] dataUsingEncoding:NSASCIIStringEncoding]];
        NSDictionary *info=nil;
        BOOL wired=NO;
        if (fd >= 0 && !connect(fd, (struct sockaddr *)&peer, sizeof(peer))) {
            struct timeval timeout = {.tv_sec=1};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            for (int i=0; i<6 && !info; i++) {
                if (send(fd, query.bytes, query.length, 0) <0) { usleep(250000); continue; }
                char buffer[8192];
                ssize_t n=recv(fd, buffer, sizeof(buffer), 0);
                if (n >0) info=ServerInfo(buffer, (size_t)n, nonce);
            }
        }
        if (!info) {
            int netError=errno;
            struct ifaddrs *list=NULL;
            BOOL wifi=NO;
            if (!getifaddrs(&list)) {
                for (struct ifaddrs *it=list; it; it=it->ifa_next)
                    if (it->ifa_addr && it->ifa_addr->sa_family==AF_INET && !strcmp(it->ifa_name, "en0")) wifi=YES;
                freeifaddrs(list);
            }
            NSLog(@"Private UDP query failed: error %d, Wi-Fi IPv4 available=%d", netError, wifi);
        }
        if (fd >=0) close(fd);
        if (!info && [parts.firstObject isEqual:[NSBundle.mainBundle objectForInfoDictionaryKey:@"BO2PrivateServer"]]
            && (port==24985 || port==24988)) {
            dispatch_async(dispatch_get_main_queue(), ^{self->_status.text=@"Checking the Mac USB connection…";});
            info=WiredServerInfo((uint16_t)port, nonce);
            wired=info!=nil;
        }
        BOOL mp=[mode isEqualToString:@"mps"];
        BOOL compatible=[info[@"sessionmode"] isEqual:mp?@"0":@"1"] && [info[@"protocol"] isEqual:mp?@"2091":@"2089"] &&
        [info[@"isInGame"] isEqual:@"1"];
        if (info) NSLog(@"Private server answered over %@, compatible=%d", wired?@"USB":@"Wi-Fi", compatible);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_checking = NO;
            if (!info) { self->_status.text=@"Server did not answer. Check Wi-Fi and Local Network access, or connect to the Mac with USB and try again."; return; }
            if (!compatible) { self->_status.text=@"The server is not running a compatible match for this mode."; return; }
            [NSUserDefaults.standardUserDefaults setObject:[parts componentsJoinedByString:@":"] forKey:[@"BO2Server." stringByAppendingString:mode]];
            self->_server=parts.firstObject;
            self->_port=(uint16_t)port;
            self->_wired=wired;
            [self start:mode];
        });
    });
}

- (void)choose:(UIButton *)sender {
    if (_checking) return;
    _server=nil;
    NSString *mode = sender.accessibilityIdentifier;
    if ([mode isEqualToString:@"mps"] || [mode isEqualToString:@"zms"]) {
        UIAlertController *menu=[UIAlertController alertControllerWithTitle:Modes()[mode] message:nil preferredStyle:UIAlertControllerStyleAlert];
        [menu addAction:[UIAlertAction actionWithTitle:@"Play Online with Steam" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self startSteam:mode online:YES];
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"Play Local" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self startLocal:mode];
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:menu animated:YES completion:nil];
        return;
    }
    [self startLocal:mode];
}

- (void)startLocal:(NSString *)mode {
    if ([NSBundle.mainBundle URLForResource:@"SteamOwnership" withExtension:@"plist"]) [self start:mode];
    else [self startSteam:mode online:NO];
}

- (void)steamInstall {
    if(_installer || _started || _checking) return;
    if(BO2GameDownload.running){ [BO2GameDownload cancel]; return; }
    if([NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Game"].hasDirectoryPath &&
       [[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Game"] checkResourceIsReachableAndReturnError:nil]){
        _status.text=@"This app already contains its game files."; return;
    }
    NSString *origin=[NSBundle.mainBundle objectForInfoDictionaryKey:@"GameLibraryOrigin"];
    if(![origin isKindOfClass:NSString.class] || !origin.length){ [self steamDownload]; return; }
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Game Files" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [menu addAction:[UIAlertAction actionWithTitle:@"Download from Steam" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ [self steamDownload]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Private Library" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ [self libraryInstall]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)steamDownload {
    if(_installer || _started || _checking || BO2GameDownload.running) return;
    NSURL *support=[NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                 appropriateForURL:nil create:NO error:nil];
    if(![[support URLByAppendingPathComponent:@"BO2GameFiles"] checkResourceIsReachableAndReturnError:nil]){ [self beginSteamDownload]; return; }
    UIAlertController *ask=[UIAlertController alertControllerWithTitle:@"Check game files with Steam?"
                                                               message:@"Game files are already installed. Any file that differs from Steam's copy will be downloaded again and replaced."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ask addAction:[UIAlertAction actionWithTitle:@"Check and Repair" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ [self beginSteamDownload]; }]];
    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ask animated:YES completion:nil];
}

- (void)beginSteamDownload {
    if(_installer || _started || _checking || BO2GameDownload.running) return;
    __weak ModePicker *weakSelf=self;
    [BO2GameDownload startWithStatus:^(NSString *text, BOOL done){
        ModePicker *picker=weakSelf;
        if(picker) picker->_status.text=text;
    }];
}

- (void)libraryInstall {
    if(_installer || _started || _checking || BO2GameDownload.running) return;
    _installer=[SteamInstaller new];
    _installer.window=self.view.window;
    __weak ModePicker *weakSelf=self;
    _installer.status=^(NSString *text, BOOL done){
        ModePicker *picker=weakSelf;
        if(!picker)return;
        picker->_status.text=text;
        if(done)picker->_installer=nil;
    };
    [_installer begin];
}

- (void)updateSteamAccount:(NSNotification *)notification {
    BOOL signedIn = [BO2SteamSignIn accountName].length > 0;
    _steamAccount.configuration = signedIn
        ? ChipLook(@"Steam · Signed in", @"checkmark.circle.fill", [UIColor colorWithRed:0.45 green:0.85 blue:0.5 alpha:1])
        : ChipLook(@"Sign in to Steam", @"person.crop.circle", nil);
}

- (void)steamAccount {
    if (_installer || _started || _checking) return;
    [BO2SteamSignIn presentFromViewController:self];
}

- (void)steamLibrary {
    if (_installer || _started || _checking) return;
    [BO2SteamSignIn presentLibraryFromViewController:self];
}

- (void)steamLibraryPlay:(NSNotification *)notification {
    NSString *mode=notification.userInfo[@"mode"];
    if (![mode isKindOfClass:NSString.class] || !Modes()[mode]) return;
    [self startSteam:mode];
}

- (void)finishSteamLaunch {
    [_steamLaunch finish];
    _steamLaunch = nil;
}

- (void)startSteam:(NSString *)mode {
    [self startSteam:mode online:NO];
}

- (void)startSteam:(NSString *)mode online:(BOOL)online {
    if (_installer || _started || _checking || !Modes()[mode]) return;
    if (BO2GameDownload.running) { _status.text=@"Game files are still downloading. Tap Game Files to pause."; return; }
    NSError *error = nil;
    NSURL *assets = GameDirectory(&error);
    if (!assets) { _status.text = error.localizedDescription; return; }
    NSURL *receiptURL = [NSBundle.mainBundle URLForResource:@"SteamOwnership" withExtension:@"plist"];
    NSDictionary *receipt = receiptURL ? [NSDictionary dictionaryWithContentsOfURL:receiptURL] : nil;
    _checking = YES;
    _server = nil;
    _status.text = @"Connecting to Steam…";
    [BO2SteamRuntime prepareMode:mode assets:assets legacySteamID:[receipt[@"account"] unsignedLongLongValue]
                   completion:^(BO2SteamLaunch *launch, NSError *failure) {
        self->_checking = NO;
        if (!launch) {
            self->_status.text = failure.localizedDescription;
            NSLog(@"[steam-runtime] preparation failed");
            return;
        }
        self->_steamLaunch = launch;
        self->_onlineRequested = online;
        [self start:mode];
        if (!self->_started) [self finishSteamLaunch];
    }];
}

- (void)start:(NSString *)mode {
    if (_installer || _started || !Modes()[mode]) return;
    if (BO2GameDownload.running) { _status.text=@"Game files are still downloading. Tap Game Files to pause."; return; }
    NSError *error = nil;
    NSURL *game = _steamLaunch ? [NSURL fileURLWithPath:_steamLaunch.gameDirectory isDirectory:YES] : GameDirectory(&error);
    if (!game) { _status.text = error.localizedDescription; return; }
    NSURL *sections = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:
                       [NSString stringWithFormat:@"Modes/%@/%@", mode, _server ? @"pluto_pe_sections.bin" : @"pe_sections.bin"]];
    if (![sections checkResourceIsReachableAndReturnError:&error]) { _status.text = error.localizedDescription; return; }
    setenv("BO2_GAME_DIR", game.fileSystemRepresentation, 1);
    ConfigureRuntime(mode);
    BOOL assist = !_server && ([mode isEqualToString:@"mps"] || [mode isEqualToString:@"zms"]);
    setenv("BO2_CONTROLLER_ASSIST", assist ? "1" : "0", 1);
    if (setenv("BO2_DW_TRANSPORT", "local", 1)) { _status.text=@"Could not configure game networking."; return; }
    if (chdir(game.fileSystemRepresentation)) { _status.text=@"Could not open the game directory."; return; }
    NSURL *library = [NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@.framework/%@", mode, mode]];
    void *handle = dlopen(library.fileSystemRepresentation, RTLD_NOW|RTLD_LOCAL);
    if (!handle) { _status.text = [NSString stringWithUTF8String:dlerror()]; return; }
    UIView *(*makeSurface)(CGRect) = (UIView *(*)(CGRect))dlsym(handle, "bo2_ios_create_surface");
    int (*entry)(const char *) = (int (*)(const char *))dlsym(handle, "bo2_ios_start");
    if (!makeSurface || !entry) { _status.text=@"Game entry point missing."; return; }
    if (_steamLaunch && ![_steamLaunch installInHandle:handle]) {
        _status.text = @"This game build does not support Steam sessions yet.";
        NSLog(@"[steam-runtime] provider ABI unavailable");
        return;
    }
    if (_steamLaunch) NSLog(@"[steam-runtime] provider installed before guest entry");
    BOOL fixture=NO, official=_onlineRequested && ([mode isEqualToString:@"mps"] || [mode isEqualToString:@"zms"]);
#if TARGET_OS_SIMULATOR
    fixture=[NSProcessInfo.processInfo.arguments containsObject:@"-BO2TransportFixturePort"];
    official |= [mode isEqualToString:@"mps"] && [NSProcessInfo.processInfo.arguments containsObject:@"-BO2ProbeOfficialMP"];
#endif
    if (_steamLaunch && (fixture || official)) {
        bool (*enableAccount)(void)=dlsym(handle, "bo2_dw_enable_account_transport");
        if (!enableAccount || !enableAccount()) {
            _status.text=@"Game networking requires an active Steam session."; return;
        }
        if (fixture) {
            NSInteger port=[NSUserDefaults.standardUserDefaults integerForKey:@"BO2TransportFixturePort"];
            bool (*configureFixture)(uint16_t)=dlsym(handle, "bo2_dw_set_loopback_fixture");
            if (port <1 || port >UINT16_MAX || !configureFixture || !configureFixture((uint16_t)port)) {
                _status.text=@"Could not start the local networking test."; return;
            }
            NSLog(@"[steam-runtime] loopback fixture configured");
        }
        if (setenv("BO2_DW_TRANSPORT", "online", 1)) { _status.text=@"Could not select game networking."; return; }
    }
    if (_server) {
        bool (*transport)(const char *, uint16_t, bool)=dlsym(handle, "bo2_pluto_start");
        void (*queue)(const char *)=dlsym(handle, "bo2_cmd_queue");
        void (*post)(uint32_t, uint32_t, uint32_t)=dlsym(handle, "ios_game_event");
        if (!queue || !post || !transport || !transport(_server.UTF8String, _port, _wired)) {
            _status.text=@"Could not start the private server connection."; return;
        }
        BOOL mp=[mode isEqualToString:@"mps"];
        NSTimeInterval connectDelay=Delay(@"BO2ConnectDelay", 65);
        NSTimeInterval keyDelay=MIN(Delay(@"BO2MenuKeyDelay", 30), connectDelay-5);
        if (mp) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(keyDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            post(0x100, 13, 1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{post(0x101, 13, 0xc0000001);});
        });
        NSString *command=[NSString stringWithFormat:@"connect %@:%u", _server, (unsigned)_port];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(connectDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            QueueConnect(handle, queue, command, mp, 2);
        });
    }
    _started = YES;
    if (_steamLaunch.personaName.length) setenv("BO2_NAME", _steamLaunch.personaName.UTF8String, 1);
    if (_steamLaunch) setenv("BO2_DW_TRACE", "0", 1);
    BeginRunLog();
    fprintf(stderr, "[fps-session] build=%s mode=%s\n",
            [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String], mode.UTF8String);
    LogDeviceState();
    for (NSNotificationName name in @[NSProcessInfoThermalStateDidChangeNotification,
                                      NSProcessInfoPowerStateDidChangeNotification, UIScreenCapturedDidChangeNotification])
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *note) { LogDeviceState(); }];
    UIView *surface = makeSurface(self.view.bounds);
    [self.view addSubview:surface];
    for (UIView *builtIn in surface.subviews.copy)
        if ([NSStringFromClass(builtIn.class) isEqualToString:@"BO2TouchControls"]) [builtIn removeFromSuperview];
    BO2TouchOverlay *touch = [[BO2TouchOverlay alloc] initWithFrame:self.view.bounds handle:handle mode:mode];
    touch.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (touch) [self.view addSubview:touch];
    if (_server) {
        UILabel *notice=[UILabel new];
        notice.text=_wired ? @"Loading private match over USB…" : @"Loading private match over Wi-Fi…";
        notice.textColor=UIColor.whiteColor;
        notice.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:0.75];
        notice.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
        notice.translatesAutoresizingMaskIntoConstraints=NO;
        [self.view addSubview:notice];
        [NSLayoutConstraint activateConstraints:@[
            [notice.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [notice.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8]
        ]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(Delay(@"BO2ConnectDelay", 65) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [notice removeFromSuperview]; });
    }
    _menu.hidden = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = entry(sections.fileSystemRepresentation);
        if (self->_steamLaunch) NSLog(@"[steam-runtime] guest returned result=%d", result);
        EndRunLog();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishSteamLaunch];
            [touch removeFromSuperview];
            [surface removeFromSuperview];
            self->_menu.hidden = NO;
            self->_status.text = [NSString stringWithFormat:@"%@ exited (%d). Reopen the app to start again.", Modes()[mode], result];
        });
    });
}

@end

@interface GameApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation GameApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ModePicker new];
    [self.window makeKeyAndVisible];
    return YES;
}
- (void)applicationDidEnterBackground:(UIApplication *)app { fflush(stderr); MarkRun(NO); }
- (void)applicationWillEnterForeground:(UIApplication *)app { if (gRunning) MarkRun(YES); }
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(GameApp.class)); }
}