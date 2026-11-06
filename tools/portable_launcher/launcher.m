#import <Cocoa/Cocoa.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../../nxnative/dm/host/romfs_image.h"

static volatile sig_atomic_t childPID;

static void forward_signal(int signalNumber) {
    pid_t child = (pid_t)childPID;
    if (child > 0) kill(child, signalNumber);
}

static BOOL regular_file(NSString *path) {
    BOOL directory = NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    return [manager fileExistsAtPath:path isDirectory:&directory] && !directory &&
           [manager isReadableFileAtPath:path];
}

static BOOL directory_exists(NSString *path) {
    BOOL directory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && directory;
}

static int report_error(NSString *title, NSString *reason, BOOL quiet) {
    fprintf(stderr, "%s: %s\n", title.UTF8String, reason.UTF8String);
    if (!quiet) {
        [NSApplication sharedApplication];
        NSAlert *alert = [NSAlert new];
        alert.messageText = title;
        alert.informativeText = reason;
        alert.alertStyle = NSAlertStyleCritical;
        [alert runModal];
    }
    return 1;
}

static NSDictionary *read_dictionary(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
}

static NSDictionary *parse_env_file(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *settings = [NSMutableDictionary new];
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange equals = [line rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:equals.location] stringByTrimmingCharactersInSet:space];
        if (![key hasPrefix:@"DM_"]) continue;
        settings[key] = [[line substringFromIndex:NSMaxRange(equals)] stringByTrimmingCharactersInSet:space];
    }
    return settings;
}

static NSString *settings_value(id value, NSDictionary *rule) {
    if (![value isKindOfClass:NSString.class] || [value length] > 256 ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    if ([rule[@"maxBytes"] isKindOfClass:NSNumber.class]) {
        return [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= [rule[@"maxBytes"] unsignedIntegerValue] ? value : nil;
    }
    if ([rule[@"values"] containsObject:value]) return value;
    NSNumber *minimum = rule[@"min"], *maximum = rule[@"max"];
    if (!minimum || !maximum) return nil;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    double number;
    if (![scanner scanDouble:&number] || !scanner.isAtEnd || !isfinite(number) ||
        number < minimum.doubleValue || number > maximum.doubleValue) return nil;
    return value;
}

static void apply_settings(NSMutableDictionary *environment, NSDictionary *settings, NSDictionary *rules) {
    for (NSString *key in rules) {
        NSString *value = settings_value(settings[key], rules[key]);
        if (value) environment[key] = value;
    }
}

static NSString *check_assets(NSString *resources, NSString *host, NSDictionary *info, BOOL performance) {
    if (!regular_file(host) || access(host.fileSystemRepresentation, X_OK)) return @"The native runtime executable is missing.";
    NSString *romfs = [resources stringByAppendingPathComponent:@"romfs.img"];
    if (!regular_file(romfs)) return @"The bundled game image (Contents/Resources/romfs.img) is missing.";
    romfs_img *image = romfs_image_open(romfs.fileSystemRepresentation);
    if (!image) return @"The bundled game image is unreadable or incomplete.";
    romfs_image_close(image);
    NSString *shaders = [resources stringByAppendingPathComponent:@"msl"];
    if (!directory_exists(shaders)) return @"The bundled Metal libraries are missing.";
    NSString *chain = info[@"DMChain"];
    if (chain) {
        if (![chain isKindOfClass:NSString.class] ||
            [chain rangeOfString:@"^[0-9a-f]{12}$" options:NSRegularExpressionSearch].location == NSNotFound)
            return @"The bundled shader chain is invalid.";
        NSString *libraries = [shaders stringByAppendingPathComponent:[@"b-" stringByAppendingString:chain]];
        BOOL found = regular_file([libraries stringByAppendingPathExtension:@"img"]);
        if (!found) {
            for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:libraries error:nil]) {
                if ([name.pathExtension isEqualToString:@"metallib"] &&
                    regular_file([libraries stringByAppendingPathComponent:name])) {
                    found = YES;
                    break;
                }
            }
        }
        if (!found) return @"The matching bundled Metal libraries are missing.";
    }
    NSArray *inventory = info[@"DMModuleFiles"];
    if (![inventory isKindOfClass:NSArray.class] || inventory.count == 0) return @"The bundled game has no native module inventory.";
    NSArray *folders = performance ? @[@"dm", @"dm-performance"] : @[@"dm"];
    for (NSString *folder in folders) {
        NSString *modules = [resources stringByAppendingPathComponent:folder];
        for (NSString *name in inventory) {
            if (![name isKindOfClass:NSString.class] || !name.length || [name containsString:@"/"] ||
                [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
                !regular_file([modules stringByAppendingPathComponent:name])) {
                return [NSString stringWithFormat:@"A required native module is missing from %@ (%@).", folder, name];
            }
        }
    }
    return nil;
}

static int spawn_game(NSString *host, NSString *modules, NSDictionary *environment) {
    size_t index = 0;
    char **variables = calloc(environment.count + 1, sizeof *variables);
    if (!variables) return ENOMEM;
    for (NSString *key in environment) {
        NSString *line = [NSString stringWithFormat:@"%@=%@", key, environment[key]];
        if (!(variables[index++] = strdup(line.UTF8String))) {
            for (size_t i = 0; i < index; i++) free(variables[i]);
            free(variables);
            return ENOMEM;
        }
    }
    char *arguments[] = {(char *)host.fileSystemRepresentation, (char *)modules.fileSystemRepresentation, NULL};
    struct sigaction action = {.sa_handler = forward_signal};
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);

    pid_t child = 0;
    int result = posix_spawn(&child, arguments[0], NULL, NULL, arguments, variables);
    for (size_t i = 0; i < index; i++) free(variables[i]);
    free(variables);
    if (result) {
        fprintf(stderr, "portable launcher: cannot start native runtime (%s)\n", strerror(result));
        return 1;
    }
    childPID = child;
    int status;
    while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return 1;
    childPID = 0;
    return WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 1;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *smoke = nil;
        BOOL check = NO, smokeWindow = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--check")) check = YES;
            else if (!strcmp(argv[i], "--smoke-dir") && i + 1 < argc) smoke = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--windowed-smoke")) smokeWindow = YES;
        }

        NSBundle *bundle = NSBundle.mainBundle;
        NSDictionary *info = bundle.infoDictionary;
        NSString *name = info[@"CFBundleName"] ?: @"Native game";
        NSString *title = info[@"DMTitleID"];
        NSString *resources = bundle.resourcePath;
        NSString *host = [bundle.executablePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"dmhost"];
        NSDictionary *manifest = read_dictionary([resources stringByAppendingPathComponent:@"portable.json"]);
        NSDictionary *profile = manifest[@"performanceProfile"];
        BOOL hasProfile = [profile isKindOfClass:NSDictionary.class];
        if (![title isKindOfClass:NSString.class] || title.length != 16 ||
            [title rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"].invertedSet].location != NSNotFound ||
            ![manifest[@"schemaVersion"] isEqual:@1] || ![manifest[@"titleID"] isEqual:title]) {
            return report_error(name, @"This app has an invalid portable game manifest. Package it again from the source app.", check || smoke != nil);
        }
        NSString *problem = check_assets(resources, host, info, hasProfile);
        if (problem) {
            return report_error(name, [problem stringByAppendingString:@" Restore the complete .app bundle or package it again."], check || smoke != nil);
        }
        if (check) {
            printf("Portable preflight passed for %s\n", title.UTF8String);
            return 0;
        }

        NSFileManager *manager = NSFileManager.defaultManager;
        NSString *applicationSupport = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/nxnative"];
        NSString *titleRoot = [applicationSupport stringByAppendingPathComponent:title];
        NSString *root = smoke ?: titleRoot;
        if (![root isAbsolutePath]) return report_error(name, @"The smoke directory must be an absolute path.", YES);
        NSString *save = [root stringByAppendingPathComponent:@"save"];
        NSString *temp = [root stringByAppendingPathComponent:@"temp"];
        NSString *logs = smoke ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/nxnative"];
        for (NSString *path in @[save, temp, logs]) {
            NSError *error = nil;
            if (![manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]) {
                return report_error(name, [NSString stringWithFormat:@"Can’t open the writable game folder %@. %@", path, error.localizedDescription], smoke != nil);
            }
        }
        NSString *lockPath = [root stringByAppendingPathComponent:@"switch2mac.lock"];
        int lock = open(lockPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (lock < 0) return report_error(name, @"Can’t open the shared save lock.", smoke != nil);
        if (flock(lock, LOCK_EX | LOCK_NB)) {
            close(lock);
            return report_error(name, @"This game is already running from another Switch2Mac copy. Close it before opening this one.", smoke != nil);
        }

        NSString *log = [logs stringByAppendingPathComponent:[title stringByAppendingString:@".portable.log"]];
        NSString *previous = [logs stringByAppendingPathComponent:[title stringByAppendingString:@".portable.prev.log"]];
        rename(log.fileSystemRepresentation, previous.fileSystemRepresentation);
        int output = open(log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
        if (output >= 0) {
            dup2(output, STDOUT_FILENO);
            dup2(output, STDERR_FILENO);
            close(output);
        }

        NSDictionary *inherited = NSProcessInfo.processInfo.environment;
        NSMutableDictionary *environment = [inherited mutableCopy];
        for (NSString *key in inherited) {
            if ([key hasPrefix:@"DM_"] || [key hasPrefix:@"DYLD_"]) [environment removeObjectForKey:key];
        }
        NSMutableDictionary *rules = [NSMutableDictionary new];
        for (NSDictionary *setting in info[@"DMSettings"]) {
            if ([setting isKindOfClass:NSDictionary.class] && [setting[@"env"] isKindOfClass:NSString.class]) {
                rules[setting[@"env"]] = setting;
            }
        }
        rules[@"DM_PAD_MERGE"] = @{@"values": @[@"0", @"1"]};
        rules[@"DM_KBD_PLAYER"] = @{@"values": @[@"shared", @"own"]};
        if ([manifest[@"capabilities"][@"preferredPlayerOneController"] boolValue]) {
            rules[@"DM_PAD_PLAYER1"] = @{@"maxBytes": @63};
        }
        rules[@"DM_AUDIO"] = @{@"values": @[@"0", @"1"]};
        rules[@"SWITCH2MAC_PERFORMANCE"] = @{@"values": @[@"0", @"1"]};
        for (NSString *key in profile[@"defaults"]) {
            if (!rules[key]) rules[key] = @{@"values": @[@"0", @"1"]};
        }

        NSString *modules = [resources stringByAppendingPathComponent:@"dm"];
        environment[@"DM_LANG"] = info[@"DMLanguage"] ?: @"en-US";
        environment[@"DM_AUDIO"] = @"1";
        [environment addEntriesFromDictionary:parse_env_file([modules stringByAppendingPathComponent:@"env.txt"])];
        NSMutableDictionary *savedChoices = [NSMutableDictionary new];
        for (NSString *key in rules) {
            NSString *preference = [@"launcher." stringByAppendingString:key];
            id value = [NSUserDefaults.standardUserDefaults objectForKey:preference];
            NSString *previousDomain = manifest[@"sourceBundleIdentifier"];
            if (!value && previousDomain.length) {
                value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)preference,
                                                                   (__bridge CFStringRef)previousDomain));
            }
            if (value) savedChoices[key] = value;
        }
        NSDictionary *legacy = parse_env_file([titleRoot stringByAppendingPathComponent:@"env.txt"]);
        NSDictionary *shared = read_dictionary([titleRoot stringByAppendingPathComponent:@"switch2mac-settings.json"]);
        NSString *performance = settings_value(inherited[@"SWITCH2MAC_PERFORMANCE"], rules[@"SWITCH2MAC_PERFORMANCE"]) ?:
                                settings_value(shared[@"SWITCH2MAC_PERFORMANCE"], rules[@"SWITCH2MAC_PERFORMANCE"]) ?: @"1";
        if (hasProfile && ![performance isEqualToString:@"0"]) {
            [environment addEntriesFromDictionary:profile[@"defaults"]];
            modules = [resources stringByAppendingPathComponent:@"dm-performance"];
        }
        apply_settings(environment, savedChoices, rules);
        apply_settings(environment, legacy, rules);
        apply_settings(environment, shared, rules);
        apply_settings(environment, inherited, rules);

        environment[@"DM_ROOT"] = root;
        environment[@"DM_SAVE"] = save;
        environment[@"DM_TEMP"] = temp;
        environment[@"DM_ROMFS"] = [resources stringByAppendingPathComponent:@"romfs.img"];
        environment[@"DM_MSL_DIR"] = [resources stringByAppendingPathComponent:@"msl"];
        environment[@"DM_FONT_DIR"] = [modules stringByAppendingPathComponent:@"font"];
        NSString *shaderMap = [modules stringByAppendingPathComponent:@"shader_map.tsv"];
        if (regular_file(shaderMap)) {
            environment[@"DM_NVN_SHMAP"] = shaderMap;
            NSString *captures = [root stringByAppendingPathComponent:@"shdump"];
            if ([NSFileManager.defaultManager createDirectoryAtPath:captures withIntermediateDirectories:YES attributes:nil error:nil])
                environment[@"DM_NVN_SHDUMP"] = captures;
        }
        NSString *pso = [resources stringByAppendingPathComponent:@"pso"];
        if (directory_exists(pso)) environment[@"DM_PSO_BUNDLE"] = pso;
        NSString *aoc = [resources stringByAppendingPathComponent:@"aoc"];
        if (directory_exists(aoc)) environment[@"DM_AOC_DIR"] = aoc;
        if (!smoke || smokeWindow) environment[@"DM_WINDOW"] = @"1";
        if (smoke) {
            environment[@"DM_AUDIO"] = @"0";
            environment[@"DM_FULLSCREEN"] = @"0";
        }
        if (chdir(root.fileSystemRepresentation)) {
            close(lock);
            return report_error(name, @"Can’t access the writable game folder.", smoke != nil);
        }

        fprintf(stderr, "portable launcher: %s (%s), resources %s, modules %s, DM_RT=%s, audio=%s\n",
                name.UTF8String, title.UTF8String, resources.UTF8String, modules.lastPathComponent.UTF8String,
                [environment[@"DM_RT"] ?: @"default" UTF8String], [environment[@"DM_AUDIO"] UTF8String]);
        int result = spawn_game(host, modules, environment);
        fprintf(stderr, "portable launcher: runtime exited with %d\n", result);
        close(lock);
        return result;
    }
}
