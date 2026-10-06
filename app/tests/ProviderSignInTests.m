#import "../ProviderSignIn.h"

int main(void) {
  @autoreleasepool {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *root = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *bin = [root stringByAppendingPathComponent:@".local/bin"];
    NSError *error = nil;
    if (![files createDirectoryAtPath:bin
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&error])
      return 1;
    NSString *output = [root stringByAppendingPathComponent:@"output"];
    NSString *stub =
        @"#!/bin/zsh\nprintf '%s\\n' \"$CODEX_HOME\" "
        @"\"${CLAUDE_CONFIG_DIR-unset}\" \"$@\" > \"$AUB_TEST_OUTPUT\"\n";
    for (NSString *cli in @[ @"claude", @"codex" ]) {
      NSString *path = [bin stringByAppendingPathComponent:cli];
      if (![stub writeToFile:path
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:&error] ||
          ![files setAttributes:@{
            NSFilePosixPermissions : @0700
          }
                   ofItemAtPath:path
                          error:&error])
        return 1;
    }
    NSString *home = @"/tmp/a b'$(exit 99); \"quoted\"\nfolder";
    for (AUBProviderKind provider = AUBProviderKindClaude;
         provider <= AUBProviderKindCodex; provider++) {
      NSString *directory =
          [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
      [files createDirectoryAtPath:directory
          withIntermediateDirectories:NO
                           attributes:nil
                                error:&error];
      NSString *path =
          [directory stringByAppendingPathComponent:@"Sign in.command"];
      [AUBProviderSignInScript(provider, home) writeToFile:path
                                                atomically:YES
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
      NSTask *task = [[NSTask alloc] init];
      task.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
      task.arguments = @[ path ];
      task.environment = @{
        @"HOME" : root,
        @"PATH" : @"/usr/bin:/bin",
        @"AUB_TEST_OUTPUT" : output,
        @"CLAUDE_CONFIG_DIR" : @"other-account",
        @"CODEX_HOME" : @"other-account"
      };
      if (error != nil || ![task launchAndReturnError:&error])
        return 1;
      [task waitUntilExit];
      NSString *actual = [NSString stringWithContentsOfFile:output
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
      NSString *expected =
          provider == AUBProviderKindClaude
              ? @"other-account\nunset\nauth\nlogin\n--claudeai\n"
              : [NSString stringWithFormat:@"%@\nother-account\nlogin\n", home];
      if (task.terminationStatus != 0 || ![actual isEqualToString:expected] ||
          [files fileExistsAtPath:directory]) {
        fprintf(
            stderr,
            "provider %u: sign-in command, home quoting, or cleanup failed\n",
            provider);
        return 1;
      }
    }
    if (AUBProviderSignInScript(AUBProviderKindCursor, home) != nil)
      return 1;
    [files removeItemAtPath:root error:&error];
    puts("ProviderSignInTests: 3 checks passed");
  }
  return 0;
}
