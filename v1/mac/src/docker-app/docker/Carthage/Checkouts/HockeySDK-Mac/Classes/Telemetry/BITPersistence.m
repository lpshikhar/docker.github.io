#import "HockeySDK.h"
#import "BITPersistence.h"
#import "BITPersistencePrivate.h"
#import "HockeySDKPrivate.h"
#import "BITHockeyHelper.h"

NSString *const kTelemetry = @"Telemetry";
NSString *const kMetaData = @"MetaData";
NSString *const kFileBaseString = @"hockey-app-bundle-";
NSString *const kFileBaseStringMeta = @"metadata";

static NSString *const kBITHockeyDirectory = @"com.microsoft.HockeyApp";
static NSString *const kBITTelemetryDirectory = @"Telemetry";
static NSString *const kBITMetaDataDirectory = @"MetaData";

NSString *const BITPersistenceSuccessNotification = @"BITHockeyPersistenceSuccessNotification";
char const *kPersistenceQueueString = "com.microsoft.HockeyApp.persistenceQueue";
NSUInteger const defaultFileCount = 50;

@interface BITPersistence ()

@property (nonatomic, strong) NSString *appHockeySDKDirectoryPath;

@end

@implementation BITPersistence {
  BOOL _maxFileCountReached;
  BOOL _directorySetupComplete;
}

#pragma mark - Public

- (instancetype)init {
  self = [super init];
  if (self) {
    _persistenceQueue = dispatch_queue_create(kPersistenceQueueString, DISPATCH_QUEUE_SERIAL); //TODO several queues?
    _requestedBundlePaths = [NSMutableArray new];
    _maxFileCount = defaultFileCount;

    // Evantually, there will be old files on disk, the flag will be updated before the first event gets created


    _maxFileCountReached = YES;
    _directorySetupComplete = NO; //will be set to true in createDirectoryStructureIfNeeded

    [self createDirectoryStructureIfNeeded];

    NSString *directoryPath = [self folderPathForType:BITPersistenceTypeTelemetry];
    NSError *error = nil;
    NSArray<NSURL *> *fileNames = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directoryPath]
                                                                includingPropertiesForKeys:@[NSURLNameKey]
                                                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                     error:&error];
    _maxFileCountReached = fileNames.count >= _maxFileCount;
  }
  return self;
}

/**
 * Saves the Bundle using NSKeyedArchiver and NSData's writeToFile:atomically
 * Sends out a BITHockeyPersistenceSuccessNotification in case of success
 */
- (void)persistBundle:(NSData *)bundle {
  //TODO send out a fail notification?
  NSString *fileURL = [self fileURLForType:BITPersistenceTypeTelemetry];

  if (bundle) {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.persistenceQueue, ^{
      typeof(self) strongSelf = weakSelf;
      BOOL success = [bundle writeToFile:fileURL atomically:YES];
      if (success) {
        BITHockeyLog(@"Wrote bundle to %@", fileURL);
        [strongSelf sendBundleSavedNotification];
      }
      else {
        BITHockeyLog(@"Error writing bundle to %@", fileURL);
      }
    });
  }
  else {
    BITHockeyLog(@"Unable to write %@ as provided bundle was null", fileURL);
  }
}

- (void)persistMetaData:(NSDictionary *)metaData {
  NSString *fileURL = [self fileURLForType:BITPersistenceTypeMetaData];
  //TODO send out a notification, too?!
  dispatch_async(self.persistenceQueue, ^{
    [NSKeyedArchiver archiveRootObject:metaData toFile:fileURL];
  });
}

- (BOOL)isFreeSpaceAvailable {
  return !_maxFileCountReached;
}

- (NSString *)requestNextFilePath {
  __block NSString *path = nil;
  __weak typeof(self) weakSelf = self;
  dispatch_sync(self.persistenceQueue, ^() {
    typeof(self) strongSelf = weakSelf;

    path = [strongSelf nextURLOfType:BITPersistenceTypeTelemetry];

    if (path) {
      [self.requestedBundlePaths addObject:path];
    }
  });
  return path;
}

- (NSDictionary *)metaData {
  NSString *filePath = [self fileURLForType:BITPersistenceTypeMetaData];
  NSObject *bundle = [self bundleAtFilePath:filePath withFileBaseString:kFileBaseStringMeta];
  if ([bundle isKindOfClass:NSDictionary.class]) {
    return (NSDictionary *) bundle;
  }
  BITHockeyLog(@"INFO: The context meta data file could not be loaded.");
  return nil;
}

- (NSObject *)bundleAtFilePath:(NSString *)filePath withFileBaseString:(NSString *)filebaseString {
  id bundle = nil;
  if (filePath && [filePath rangeOfString:filebaseString].location != NSNotFound) {
    bundle = [NSKeyedUnarchiver unarchiveObjectWithFile:filePath];
  }
  return bundle;
}

- (NSData *)dataAtFilePath:(NSString *)path {
  NSData *data = nil;
  if (path && [path rangeOfString:kFileBaseString].location != NSNotFound) {
    data = [NSData dataWithContentsOfFile:path];
  }
  return data;
}

/**
 * Deletes a file at the given path.
 *
 * @param the path to look for a file and delete it.
 */
- (void)deleteFileAtPath:(NSString *)path {
  __weak typeof(self) weakSelf = self;
  dispatch_sync(self.persistenceQueue, ^() {
    typeof(self) strongSelf = weakSelf;
    if ([path rangeOfString:kFileBaseString].location != NSNotFound) {
      NSError *error = nil;
      if (![[NSFileManager defaultManager] removeItemAtPath:path error:&error]) {
        BITHockeyLog(@"Error deleting file at path %@", path);
      }
      else {
        BITHockeyLog(@"Successfully deleted file at path %@", path);
        [strongSelf.requestedBundlePaths removeObject:path];
      }
    } else {
      BITHockeyLog(@"Empty path, nothing to delete");
    }
  });

}

- (void)giveBackRequestedFilePath:(NSString *)filePath {
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.persistenceQueue, ^() {
    typeof(self) strongSelf = weakSelf;

    [strongSelf.requestedBundlePaths removeObject:filePath];
  });
}

#pragma mark - Private

- (NSString *)fileURLForType:(BITPersistenceType)type {

  NSString *fileName = nil;
  NSString *filePath;

  switch (type) {
    case BITPersistenceTypeMetaData: {
      fileName = kFileBaseStringMeta;
      filePath = [self.appHockeySDKDirectoryPath stringByAppendingPathComponent:kBITMetaDataDirectory];
      break;
    };
    default: {
      NSString *uuid = bit_UUID();
      fileName = [NSString stringWithFormat:@"%@%@", kFileBaseString, uuid];
      filePath = [self.appHockeySDKDirectoryPath stringByAppendingPathComponent:kBITTelemetryDirectory];
      break;
    };
  }

  filePath = [filePath stringByAppendingPathComponent:fileName];

  return filePath;
}

/**
 * Create directory structure if necessary and exclude it from iCloud backup
 */
- (void)createDirectoryStructureIfNeeded {
  
  NSURL *appURL = [NSURL fileURLWithPath:self.appHockeySDKDirectoryPath];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  if (appURL) {
    NSError *error = nil;
    // Create HockeySDK folder if needed
    if (![fileManager createDirectoryAtURL:appURL withIntermediateDirectories:YES attributes:nil error:&error]) {
      BITHockeyLog(@"%@", error.localizedDescription);
      return;
    }
    
    // Create metadata subfolder
    NSURL *metaDataURL = [appURL URLByAppendingPathComponent:kBITMetaDataDirectory];
    if (![fileManager createDirectoryAtURL:metaDataURL withIntermediateDirectories:YES attributes:nil error:&error]) {
      BITHockeyLog(@"%@", error.localizedDescription);
      return;
    }
    
    // Create telemetry subfolder
    
    // NOTE: createDirectoryAtURL:withIntermediateDirectories:attributes:error
    // will return YES if the directory already exists and won't override anything.
    // No need to check if the directory already exists.
    NSURL *telemetryURL = [appURL URLByAppendingPathComponent:kBITTelemetryDirectory];
    if (![fileManager createDirectoryAtURL:telemetryURL withIntermediateDirectories:YES attributes:nil error:&error]) {
      BITHockeyLog(@"%@", error.localizedDescription);
      return;
    }

    // Make sure NSURLIsExcludedFromBackupKey is available
    if (&NSURLIsExcludedFromBackupKey != NULL) {
      //Exclude HockeySDK folder from backup
      if (![appURL setResourceValue:@YES
                             forKey:NSURLIsExcludedFromBackupKey
                              error:&error]) {
        BITHockeyLog(@"ERROR: Error excluding %@ from backup %@", appURL.lastPathComponent, error.localizedDescription);
      } else {
        BITHockeyLog(@"INFO: Exclude %@ from backup", appURL);
      }
    }
    
    _directorySetupComplete = YES;
  }
}

/**
 * @returns the URL to the next file depending on the specified type. If there's no file, return nil.
 */
- (NSString *)nextURLOfType:(BITPersistenceType)type {
  NSString *directoryPath = [self folderPathForType:type];
  NSError *error = nil;
  NSArray<NSURL *> *fileNames = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directoryPath]
                                                              includingPropertiesForKeys:@[NSURLNameKey]
                                                                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                   error:&error];
  
  // Each track method asks if space is still available. Getting the file count for each event would be too expensive,
  // so let's get it here
  if (type == BITPersistenceTypeTelemetry) {
    _maxFileCountReached = fileNames.count >= _maxFileCount;
  }

  if (fileNames && fileNames.count > 0) {
    for (NSURL *filename in fileNames) {
      NSString *absolutePath = filename.path;
      if (![self.requestedBundlePaths containsObject:absolutePath]) {
        return absolutePath;
      }
    }
  }
  return nil;
}

- (NSString *)folderPathForType:(BITPersistenceType)type {

  NSString *subFolder = @"";
  switch (type) {
    case BITPersistenceTypeTelemetry: {
      subFolder = kBITTelemetryDirectory;
      break;
    }
    case BITPersistenceTypeMetaData: {
      subFolder = kBITMetaDataDirectory;
      break;
    }
  }
  return [self.appHockeySDKDirectoryPath stringByAppendingPathComponent:subFolder];
}

/**
 * Send a BITHockeyPersistenceSuccessNotification to the main thread to notify observers that we have successfully saved a file
 * This is typically used to trigger sending.
 */
- (void)sendBundleSavedNotification {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:BITPersistenceSuccessNotification
                                                        object:nil
                                                      userInfo:nil];
  });
}

- (NSString *)appHockeySDKDirectoryPath {
  if (!_appHockeySDKDirectoryPath) {
    
    // Assemble the directory path we use to store our telemetry data in.
    // We use the current app's bundle identifier for the name of the subfolder within Application Support
    // as this is one of the few directories a sandboxed app can write to (Compare
    // https://developer.apple.com/library/mac/documentation/General/Conceptual/MOSXAppProgrammingGuide/AppRuntime/AppRuntime.html#//apple_ref/doc/uid/TP40010543-CH2-SW9 )
    // and then create our own subfolder within that.
    NSString *appSupportPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject] stringByStandardizingPath];
    NSString *bundleID = [self bundleIdentifier];
    
    if (appSupportPath && bundleID) {
      _appHockeySDKDirectoryPath = [[appSupportPath stringByAppendingPathComponent:bundleID] stringByAppendingPathComponent:kBITHockeyDirectory];
    }
  }
  return _appHockeySDKDirectoryPath;
}

- (NSString *)bundleIdentifier {
  return bit_mainBundleIdentifier();
}

@end