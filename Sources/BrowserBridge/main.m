// Reuse upstream's pairing, AFC session and file primitives unchanged.
// The upstream PoC entry point is never called by this browser.
#define main AirliftPoCMain
#include "../../airlift/Sources/device_helper.m"
#undef main
#include <signal.h>

extern int AMDeviceGetInterfaceType(AMDeviceRef device);
extern int AFCRenamePath(AFCConnectionRef afc, const char *source, const char *destination);

static NSMutableDictionary *Devices;
static NSDictionary *Failure(NSString *message) {
    return @{ @"ok": @NO, @"error": message };
}

static void Discover(AMDeviceNotificationCallbackInfo *info, void *context) {
    (void)context;
    if (!info || info->message != 1 || AMDeviceGetInterfaceType(info->device) != 1) return;
    AMDeviceRef device = info->device;
    if (AMDeviceConnect(device) != 0) return;
    NSString *udid = CFBridgingRelease(AMDeviceCopyDeviceIdentifier(device));
    NSString *name = CFBridgingRelease(AMDeviceCopyValue(device, NULL, CFSTR("DeviceName")));
    NSString *product = CFBridgingRelease(AMDeviceCopyValue(device, NULL, CFSTR("ProductType")));
    NSString *version = CFBridgingRelease(AMDeviceCopyValue(device, NULL, CFSTR("ProductVersion")));
    if (udid && AMDeviceIsPaired(device) &&
        ([product hasPrefix:@"iPad"] || [product hasPrefix:@"iPhone"])) {
        Devices[udid] = @{ @"id": udid, @"name": name ?: product,
                          @"product": product, @"version": version ?: @"", @"transport": @"USB" };
    }
    AMDeviceDisconnect(device);
}

static NSDictionary *DiscoverDevices(void) {
    Devices = NSMutableDictionary.dictionary;
    AMDeviceNotificationRef subscription = NULL;
    NSDictionary *options = @{
        @"NotificationOptionSearchForPairedDevices": @YES,
        @"NotificationOptionSearchForPairedDevicesViaDirectConnectionsOnly": @YES,
        @"NotificationOptionEnableUSBMux": @YES
    };
    int status = AMDeviceNotificationSubscribeWithOptions(Discover, 0, 0, NULL,
        &subscription, (__bridge CFDictionaryRef)options);
    if (!status) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false);
    if (subscription) AMDeviceNotificationUnsubscribe(subscription);
    return status ? Failure(@"USB端末の検出に失敗しました。")
                  : @{ @"ok": @YES, @"devices": Devices.allValues };
}

static BOOL ValidPath(NSString *path) {
    if (![path hasPrefix:@"/"] || path.length > 1024) return NO;
    if ([path isEqual:@"/"]) return YES;
    for (NSString *part in [[path substringFromIndex:1] componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}

// Reject symbolic-link ancestors; this UI exposes the AFC Media root, not a root filesystem.
static BOOL Traversable(AFCConnectionRef afc, NSString *path, BOOL includeLeaf) {
    NSString *cursor = @"/";
    NSArray *parts = [[path substringFromIndex:1] componentsSeparatedByString:@"/"];
    NSUInteger count = includeLeaf ? parts.count : parts.count - 1;
    for (NSUInteger i = 0; i < count; i++) {
        if (![parts[i] length]) continue;
        cursor = [cursor stringByAppendingPathComponent:parts[i]];
        if (![AFCFileKind(afc, cursor) isEqual:@"S_IFDIR"]) return NO;
    }
    return YES;
}

static NSDictionary *List(AFCConnectionRef afc, NSString *path) {
    if (!Traversable(afc, path, YES)) return Failure(@"フォルダが見つからないか、リンク先です。");
    AFCDirectoryRef directory = NULL;
    int status = AFCDirectoryOpen(afc, path.fileSystemRepresentation, &directory);
    if (status || !directory) return Failure(@"フォルダを開けませんでした。");
    NSMutableArray *entries = NSMutableArray.array;
    char *raw = NULL;
    while ((status = AFCDirectoryRead(afc, directory, &raw)) == 0 && raw) {
        NSString *name = [NSString stringWithUTF8String:raw];
        if (!name || [name isEqual:@"."] || [name isEqual:@".."]) continue;
        NSString *child = [path stringByAppendingPathComponent:name];
        NSString *kind = AFCFileKind(afc, child) ?: @"unknown";
        [entries addObject:@{ @"id": child, @"name": name, @"kind": kind,
                              @"size": @(AFCFileSize(afc, child)) }];
    }
    int closed = AFCDirectoryClose(afc, directory);
    if (status || closed) return Failure(@"一覧の読み込みが中断されました。再接続してください。");
    return @{ @"ok": @YES, @"entries": entries };
}

// ponytail: bounded in-memory transfers (128 MiB); use streaming for larger files.
static const long long TransferLimit = 128 * 1024 * 1024;

static NSDictionary *FinishWrite(AFCConnectionRef afc, NSArray<NSString *> *args) {
    NSString *source = args[0];
    NSString *link = args[1];
    NSString *recovered = args[2];
    NSData *expected = [NSData dataWithContentsOfFile:args[3]];
    NSString *targetTail = args[4];
    NSString *leaf = args[5];
    NSString *snapshotRoot = args[6];
    NSDictionary *snapshot = LoadBooksSnapshot(snapshotRoot);
    BOOL safe = GeneratedNamesMatch(source, link, recovered) &&
        IsSafeRelativePath(targetTail) && IsSafeRelativePath(leaf) &&
        [leaf rangeOfString:@"/"].location == NSNotFound &&
        leaf.length <= 255 && expected.length <= TransferLimit && snapshot != nil;
    if (!safe) return Failure(@"書込み後処理の引数を検証できませんでした。");

    BOOL restoredToTarget = !AFCExists(afc, recovered);
    NSMutableArray *failures = NSMutableArray.array;
    if (!RemoveIfPresent(afc, link)) [failures addObject:@"一時リンク"];
    if (!RemoveGeneratedTree(afc, source, 0)) [failures addObject:@"展開ディレクトリ"];
    usleep(200000);
    NSDictionary *restore = RestoreBooksState(afc, snapshotRoot);
    if (![restore[@"ok"] boolValue]) [failures addObject:@"Books同期状態"];
    BOOL cleanup = failures.count == 0;
    if (!restoredToTarget)
        return @{ @"ok": @NO,
                  @"error": [NSString stringWithFormat:
                      @"対象への最終配置を確認できませんでした。回収データをMedia/%@に保持しています。", recovered],
                  @"cleanupComplete": @(cleanup) };
    return cleanup
        ? @{ @"ok": @YES, @"bytes": @(expected.length), @"cleanupComplete": @YES }
        : @{ @"ok": @NO,
             @"error": [NSString stringWithFormat:@"書込みは完了しましたが後片付けに失敗: %@",
                         [failures componentsJoinedByString:@", "]],
             @"bytesMatch": @YES, @"cleanupComplete": @NO };
}

static NSDictionary *FinishDelete(AFCConnectionRef afc, NSArray<NSString *> *args) {
    NSString *source = args[0];
    NSString *link = args[1];
    NSString *recovered = args[2];
    NSString *snapshotRoot = args[3];
    NSString *mode = args[4];
    NSDictionary *snapshot = LoadBooksSnapshot(snapshotRoot);
    BOOL deleteRequested = [mode isEqual:@"delete"];
    BOOL cleanupOnly = [mode isEqual:@"cleanup"];
    BOOL safe = GeneratedNamesMatch(source, link, recovered) && snapshot != nil &&
        (deleteRequested || cleanupOnly);
    if (!safe) return Failure(@"削除後処理の引数を検証できませんでした。");

    NSString *kind = AFCFileKind(afc, recovered);
    BOOL deleted = deleteRequested && [kind isEqual:@"S_IFREG"] &&
        AFCRemovePath(afc, recovered.fileSystemRepresentation) == 0 && !AFCExists(afc, recovered);
    BOOL settled = deleteRequested ? deleted : !AFCExists(afc, recovered);
    NSMutableArray *failures = NSMutableArray.array;
    if (!RemoveIfPresent(afc, link)) [failures addObject:@"一時リンク"];
    if (!RemoveGeneratedTree(afc, source, 0)) [failures addObject:@"展開ディレクトリ"];
    usleep(200000);
    NSDictionary *restore = RestoreBooksState(afc, snapshotRoot);
    if (![restore[@"ok"] boolValue]) [failures addObject:@"Books同期状態"];
    BOOL cleanup = failures.count == 0;
    if (!settled)
        return @{ @"ok": @NO,
                  @"error": [NSString stringWithFormat:
                      @"対象を確定できませんでした。回収できたデータはMedia/%@に保持しています。", recovered],
                  @"deleted": @NO, @"cleanupComplete": @(cleanup) };
    if (cleanupOnly)
        return cleanup
            ? @{ @"ok": @YES, @"deleted": @NO, @"targetAbsent": @NO,
                 @"cleanupComplete": @YES }
            : @{ @"ok": @NO, @"error": @"復元後の後片付けに失敗しました。",
                 @"deleted": @NO, @"cleanupComplete": @NO };
    return cleanup
        ? @{ @"ok": @YES, @"deleted": @YES, @"targetAbsent": @YES,
             @"cleanupComplete": @YES }
        : @{ @"ok": @NO,
             @"error": [NSString stringWithFormat:@"削除は完了しましたが後片付けに失敗: %@",
                         [failures componentsJoinedByString:@", "]],
             @"deleted": @YES, @"targetAbsent": @YES, @"cleanupComplete": @NO };
}

static NSDictionary *VerifyRecovered(AFCConnectionRef afc, NSString *path,
                                     NSString *expectedPath) {
    if (!GeneratedToken(path, AIRLIFT_RECOVERED_PREFIX))
        return Failure(@"回収ファイル名を検証できませんでした。");
    NSData *expected = [NSData dataWithContentsOfFile:expectedPath];
    if (!expected || expected.length > TransferLimit)
        return Failure(@"照合元ファイルを読み込めませんでした。");
    NSData *observed = AFCReadFileWithLimit(afc, path, TransferLimit);
    return observed && [observed isEqualToData:expected]
        ? @{ @"ok": @YES, @"bytes": @(observed.length) }
        : Failure(@"回収したファイルが元データと一致しませんでした。");
}

static NSDictionary *WaitRecovered(AFCConnectionRef afc, NSString *path, NSString *mode) {
    if (!GeneratedToken(path, AIRLIFT_RECOVERED_PREFIX))
        return Failure(@"回収ファイル名を検証できませんでした。");
    BOOL wantAbsent = [mode isEqual:@"absent"];
    BOOL wantDirectory = [mode isEqual:@"directory"];
    BOOL wantFile = [mode isEqual:@"file"];
    if (!wantAbsent && !wantDirectory && !wantFile)
        return Failure(@"回収データの待ち方が不正です。");
    for (NSUInteger attempt = 0; attempt < 80; attempt++) {
        BOOL exists = AFCExists(afc, path);
        NSString *kind = exists ? AFCFileKind(afc, path) : nil;
        BOOL ready = (wantAbsent && !exists) ||
            (wantDirectory && [kind isEqual:@"S_IFDIR"]) ||
            (wantFile && [kind isEqual:@"S_IFREG"]);
        if (ready) return @{ @"ok": @YES, @"attempts": @(attempt + 1), @"kind": kind ?: @"" };
        usleep(50000);
    }
    return Failure(@"回収データの状態が変わる前に時間切れになりました。");
}

static NSDictionary *GeneratedExists(AFCConnectionRef afc, NSString *path) {
    BOOL safe = GeneratedToken(path, AIRLIFT_RECOVERED_PREFIX) != nil;
    return safe ? @{ @"ok": @YES, @"exists": @(AFCExists(afc, path)) }
                : Failure(@"生成ファイル名を検証できませんでした。");
}

static NSDictionary *GeneratedKind(AFCConnectionRef afc, NSString *path) {
    if (!GeneratedToken(path, AIRLIFT_RECOVERED_PREFIX))
        return Failure(@"生成ファイル名を検証できませんでした。");
    NSString *kind = AFCFileKind(afc, path);
    return kind ? @{ @"ok": @YES, @"kind": kind }
                : Failure(@"回収対象を確認できませんでした。");
}

static NSDictionary *Operate(AFCConnectionRef afc, NSString *command, NSString *path, NSString *argument) {
    if (!ValidPath(path)) return Failure(@"不正なMedia相対パスです。");
    if ([command isEqual:@"list"]) return List(afc, path);
    if ([path isEqual:@"/"] || !Traversable(afc, path, NO))
        return Failure(@"Mediaルートやリンク経由の操作は対象外です。");
    NSString *kind = AFCFileKind(afc, path);
    if ([command isEqual:@"get"] && argument) {
        if (![kind isEqual:@"S_IFREG"]) return Failure(@"通常ファイルを選択してください。");
        NSData *data = AFCReadFileWithLimit(afc, path, TransferLimit);
        if (!data) return Failure(@"読み込み失敗、または128 MiBを超えています。");
        NSError *error = nil;
        if (![data writeToFile:argument options:NSDataWritingWithoutOverwriting error:&error])
            return Failure(error.localizedDescription);
        NSData *saved = [NSData dataWithContentsOfFile:argument];
        return [data isEqualToData:saved] ? @{ @"ok": @YES, @"bytes": @(data.length) }
            : Failure(@"保存後の照合に失敗しました。保存先を確認してください。");
    }
    if ([command isEqual:@"put"] && argument) {
        if (kind) return Failure(@"同名の項目があります。上書きせず別名で送信してください。");
        NSError *error = nil;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:argument error:&error];
        if (!attributes) return Failure(error.localizedDescription);
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] longLongValue] > TransferLimit)
            return Failure(@"送信は128 MiB以下の通常ファイルが対象です。");
        NSData *data = [NSData dataWithContentsOfFile:argument options:NSDataReadingMappedIfSafe error:&error];
        if (!data || data.length > TransferLimit) return Failure(error.localizedDescription ?: @"サイズ上限を超えています。");
        NSString *temporary = [[path stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:[@".airlift-upload-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        if (AFCExists(afc, temporary)) return Failure(@"一時ファイル名が衝突しました。");
        BOOL written = AFCWriteFile(afc, temporary, data);
        BOOL verified = written && [AFCReadFileWithLimit(afc, temporary, TransferLimit) isEqualToData:data];
        BOOL moved = verified && !AFCExists(afc, path) &&
            AFCRenamePath(afc, temporary.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
        if (!moved) {
            BOOL cleaned = RemoveIfPresent(afc, temporary);
            return Failure([NSString stringWithFormat:@"転送・照合が完了しませんでした。%@",
                cleaned ? @"一時ファイルは削除済みです。" : [@"残った一時ファイル: " stringByAppendingString:temporary]]);
        }
        return @{ @"ok": @YES, @"bytes": @(data.length) };
    }
    if ([command isEqual:@"mkdir"]) {
        if (kind) return Failure(@"同名の項目があります。");
        return AFCDirectoryCreate(afc, path.fileSystemRepresentation) == 0
            ? @{ @"ok": @YES } : Failure(@"フォルダ作成に失敗しました。");
    }
    if ([command isEqual:@"rename"] && argument) {
        if (!ValidPath(argument) || [argument isEqual:@"/"] || !Traversable(afc, argument, NO) || AFCExists(afc, argument))
            return Failure(@"移動先が不正か、同名の項目があります。");
        if (!kind || [kind isEqual:@"S_IFLNK"]) return Failure(@"対象が見つからないか、シンボリックリンクです。");
        return AFCRenamePath(afc, path.fileSystemRepresentation, argument.fileSystemRepresentation) == 0
            ? @{ @"ok": @YES } : Failure(@"名前変更に失敗しました。");
    }
    if ([command isEqual:@"remove"]) {
        if ([kind isEqual:@"S_IFDIR"]) {
            NSDictionary *listing = List(afc, path);
            if (![listing[@"ok"] boolValue] || [listing[@"entries"] count])
                return Failure(@"空のフォルダだけ削除できます。");
        } else if (![kind isEqual:@"S_IFREG"]) return Failure(@"通常ファイルまたは空のフォルダを選択してください。");
        return AFCRemovePath(afc, path.fileSystemRepresentation) == 0
            ? @{ @"ok": @YES } : Failure(@"削除に失敗しました。");
    }
    return Failure(@"不明な操作、または引数不足です。");
}

// Wallet券面の表示に必要なファイルだけ。証明書やその他のパス内容はコピーしない。
static BOOL SafeCatalogName(NSString *name) {
    if (!name.length || name.length > 255) return NO;
    if ([name isEqual:@"."] || [name isEqual:@".."]) return NO;
    return [name rangeOfString:@"/"].location == NSNotFound;
}

static NSArray<NSString *> *CatalogChildren(AFCConnectionRef afc, NSString *path, BOOL *ok) {
    *ok = NO;
    AFCDirectoryRef directory = NULL;
    if (AFCDirectoryOpen(afc, path.fileSystemRepresentation, &directory) != 0 || !directory)
        return nil;
    NSMutableArray<NSString *> *children = NSMutableArray.array;
    BOOL readOK = YES;
    for (NSUInteger index = 0; index < 4000; index++) {
        char *raw = NULL;
        if (AFCDirectoryRead(afc, directory, &raw) != 0) { readOK = NO; break; }
        if (!raw) break;
        NSString *name = [NSString stringWithUTF8String:raw];
        if (!name || [name isEqual:@"."] || [name isEqual:@".."]) continue;
        if (!SafeCatalogName(name)) { readOK = NO; break; }
        [children addObject:name];
    }
    BOOL closeOK = AFCDirectoryClose(afc, directory) == 0;
    *ok = readOK && closeOK;
    return *ok ? children : nil;
}

static NSString *CardIDFromContainer(NSString *container) {
    for (NSString *suffix in @[ @".cache", @".pkpass" ]) {
        if ([container hasSuffix:suffix] && container.length > suffix.length)
            return [container substringToIndex:container.length - suffix.length];
    }
    return nil;
}

static BOOL IsCatalogFile(NSString *container, NSString *file, NSSet<NSString *> *cardIDs) {
    NSString *cardID = CardIDFromContainer(container);
    if (!cardID || ![cardIDs containsObject:cardID]) return NO;
    if ([container hasSuffix:@".cache"])
        return [file isEqual:@"FrontFace"] || [file isEqual:@"PlaceHolder"] || [file isEqual:@"Preview"];
    if (![container hasSuffix:@".pkpass"]) return NO;
    return [file isEqual:@"pass.json"] ||
        [file hasPrefix:@"cardBackgroundCombined"] ||
        [file hasPrefix:@"backgroundParallax"] ||
        [file hasPrefix:@"foregroundParallax"] ||
        [file hasPrefix:@"staticOverlay"] ||
        [file hasPrefix:@"dynamicLayerStaticFallback"];
}

static NSSet<NSString *> *PaymentCardIDs(AFCConnectionRef afc, NSString *root, BOOL *ok) {
    BOOL listed = NO;
    NSArray<NSString *> *children = CatalogChildren(afc, root, &listed);
    if (!listed) { *ok = NO; return nil; }
    NSMutableSet<NSString *> *identifiers = NSMutableSet.set;
    for (NSString *name in children) {
        if (![name hasSuffix:@".pkpass"] || ![AFCFileKind(afc, [root stringByAppendingPathComponent:name]) isEqual:@"S_IFDIR"])
            continue;
        NSString *passJSON = [[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"pass.json"];
        if (![AFCFileKind(afc, passJSON) isEqual:@"S_IFREG"]) continue;
        NSData *data = AFCReadFileWithLimit(afc, passJSON, 1024 * 1024);
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([value isKindOfClass:NSDictionary.class] && [(NSDictionary *)value objectForKey:@"paymentCard"]) {
            NSString *cardID = CardIDFromContainer(name);
            if (cardID) [identifiers addObject:cardID];
        }
    }
    *ok = YES;
    return identifiers;
}

static NSData *SanitizedPassJSON(NSData *original) {
    id value = [NSJSONSerialization JSONObjectWithData:original options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class] || ![(NSDictionary *)value objectForKey:@"paymentCard"])
        return nil;
    NSDictionary *metadata = value;
    NSMutableDictionary *safe = [NSMutableDictionary dictionaryWithObject:@YES forKey:@"paymentCard"];
    for (NSString *key in @[ @"organizationName", @"description" ]) {
        id text = metadata[key];
        if ([text isKindOfClass:NSString.class] && [text length] <= 200)
            safe[key] = text;
    }
    for (NSString *key in @[ @"primaryAccountNumberSuffix", @"primaryAccountSuffix" ]) {
        id suffix = metadata[key];
        if (![suffix isKindOfClass:NSString.class] || [suffix length] != 4) continue;
        if ([suffix rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound)
            continue;
        safe[@"primaryAccountNumberSuffix"] = suffix;
        break;
    }
    return [NSJSONSerialization dataWithJSONObject:safe options:0 error:nil];
}

static BOOL AcceptNewLocalDirectory(NSString *path) {
    if (![path hasPrefix:@"/"] || path.length < 2 || path.length > 1024 || [path hasSuffix:@"/"]) return NO;
    for (NSString *part in path.pathComponents)
        if ([part isEqual:@".."]) return NO;
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL directory = NO;
    NSString *parent = path.stringByDeletingLastPathComponent;
    if (![files fileExistsAtPath:parent isDirectory:&directory] || !directory) return NO;
    return ![files fileExistsAtPath:path];
}

static NSDictionary *PullCardCatalog(AFCConnectionRef afc, NSString *remoteName, NSString *localPath) {
    if (!GeneratedToken(remoteName, AIRLIFT_RECOVERED_PREFIX))
        return Failure(@"回収ディレクトリ名を検証できませんでした。");
    if (![AFCFileKind(afc, remoteName) isEqual:@"S_IFDIR"])
        return Failure(@"回収したCardsディレクトリが見つかりません。");
    if (!AcceptNewLocalDirectory(localPath))
        return Failure(@"カード一覧の保存先が不正か、既に存在します。");
    BOOL scanned = NO;
    NSSet<NSString *> *cardIDs = PaymentCardIDs(afc, remoteName, &scanned);
    if (!scanned) return Failure(@"Cardsディレクトリを読めませんでした。");
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:localPath withIntermediateDirectories:NO attributes:nil error:&error])
        return Failure(error.localizedDescription ?: @"保存先を作成できませんでした。");

    BOOL listed = NO;
    NSArray<NSString *> *children = CatalogChildren(afc, remoteName, &listed);
    if (!listed) return Failure(@"Cardsディレクトリの一覧が中断されました。");
    NSUInteger files = 0;
    unsigned long long bytes = 0;
    for (NSString *container in children) {
        NSString *cardID = CardIDFromContainer(container);
        if (!cardID || ![cardIDs containsObject:cardID]) continue;
        NSString *remoteContainer = [remoteName stringByAppendingPathComponent:container];
        if (![AFCFileKind(afc, remoteContainer) isEqual:@"S_IFDIR"]) continue;
        BOOL childOK = NO;
        NSArray<NSString *> *inner = CatalogChildren(afc, remoteContainer, &childOK);
        if (!childOK) return Failure(@"カード内の一覧が中断されました。");
        NSString *localContainer = [localPath stringByAppendingPathComponent:container];
        BOOL wroteDirectory = NO;
        for (NSString *file in inner) {
            if (!IsCatalogFile(container, file, cardIDs)) continue;
            NSString *remoteFile = [remoteContainer stringByAppendingPathComponent:file];
            if (![AFCFileKind(afc, remoteFile) isEqual:@"S_IFREG"]) continue;
            BOOL passJSON = [file isEqual:@"pass.json"];
            BOOL urlsFile = [file hasSuffix:@".urls"];
            NSData *data = AFCReadFileWithLimit(afc, remoteFile, passJSON || urlsFile ? 1024 * 1024 : 16 * 1024 * 1024);
            if (passJSON) data = data ? SanitizedPassJSON(data) : nil;
            if (!data) {
                if (passJSON || urlsFile) continue;
                return Failure(@"券面ファイルを読み出せませんでした。");
            }
            if (bytes + data.length > 128ULL * 1024 * 1024)
                return Failure(@"券面ファイルがサイズ上限を超えました。");
            if (!wroteDirectory) {
                if (![NSFileManager.defaultManager createDirectoryAtPath:localContainer
                                               withIntermediateDirectories:NO attributes:nil error:&error])
                    return Failure(error.localizedDescription ?: @"カードフォルダを作成できませんでした。");
                wroteDirectory = YES;
            }
            if (![data writeToFile:[localContainer stringByAppendingPathComponent:file]
                           options:NSDataWritingWithoutOverwriting error:&error])
                return Failure(error.localizedDescription ?: @"券面ファイルを保存できませんでした。");
            files++;
            bytes += data.length;
        }
    }
    return @{ @"ok": @YES, @"fileCount": @(files), @"totalBytes": @(bytes),
              @"paymentCardCount": @(cardIDs.count) };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // A disconnected private service must not leave a hung background process.
        alarm(120);
        if (argc == 2 && strcmp(argv[1], "devices") == 0) {
            NSDictionary *result = DiscoverDevices();
            PrintJSON(result);
            return [result[@"ok"] boolValue] ? 0 : 1;
        }
        if (argc < 4 || argc > 10) { PrintJSON(Failure(@"引数不足です。")); return 64; }
        TargetIdentifier = CFStringCreateWithCString(NULL, argv[2], kCFStringEncodingUTF8);
        DeviceSession session;
        OpenSession(&session);
        NSDictionary *result;
        if (!session.afc || session.afcStatus || AMDeviceGetInterfaceType(session.device) != 1) {
            result = Failure(@"USB接続・ロック解除・『このコンピュータを信頼』を確認して再試行してください。");
        } else if (strcmp(argv[1], "finish-write") == 0 && argc == 10) {
            result = FinishWrite(session.afc, @[
                @(argv[3]), @(argv[4]), @(argv[5]), @(argv[6]),
                @(argv[7]), @(argv[8]), @(argv[9])
            ]);
        } else if (strcmp(argv[1], "finish-delete") == 0 && argc == 8) {
            result = FinishDelete(session.afc, @[
                @(argv[3]), @(argv[4]), @(argv[5]), @(argv[6]), @(argv[7])
            ]);
        } else if (strcmp(argv[1], "verify-recovered") == 0 && argc == 5) {
            result = VerifyRecovered(session.afc, @(argv[3]), @(argv[4]));
        } else if (strcmp(argv[1], "wait-recovered") == 0 && argc == 5) {
            result = WaitRecovered(session.afc, @(argv[3]), @(argv[4]));
        } else if (strcmp(argv[1], "generated-exists") == 0 && argc == 4) {
            result = GeneratedExists(session.afc, @(argv[3]));
        } else if (strcmp(argv[1], "generated-kind") == 0 && argc == 4) {
            result = GeneratedKind(session.afc, @(argv[3]));
        } else if (strcmp(argv[1], "pull-card-catalog") == 0 && argc == 5) {
            result = PullCardCatalog(session.afc, @(argv[3]), @(argv[4]));
        } else {
            result = Operate(session.afc, @(argv[1]), @(argv[3]), argc == 5 ? @(argv[4]) : nil);
        }
        PrintJSON(result);
        CloseSession(&session);
        CFRelease(TargetIdentifier);
        return [result[@"ok"] boolValue] ? 0 : 1;
    }
}
