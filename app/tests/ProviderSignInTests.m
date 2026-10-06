#import "../ProviderSignIn.h"

int main(void) {
  @autoreleasepool {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *root = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *bin = [root stringByAppendingPathComponent:@"npm/bin"];
    NSError *error = nil;
    if (![files createDirectoryAtPath:bin
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&error])
      return 1;
    NSString *profile = [root stringByAppendingPathComponent:@".zprofile"];
    NSString *rc = [root stringByAppendingPathComponent:@".zshrc"];
    if (![@"export AUB_TEST_LOGIN_STARTED=yes\n"
            writeToFile:profile
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:&error] ||
        ![@"export PATH=\"$HOME/npm/bin:$PATH\"\nexport "
          @"AUB_TEST_INTERACTIVE_STARTED=yes\n" writeToFile:rc
                                                 atomically:YES
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error])
      return 1;
    NSString *output = [root stringByAppendingPathComponent:@"output"];
    NSString *stub =
        @"#!/bin/zsh\n[[ \"$AUB_TEST_LOGIN_STARTED\" = yes && "
        @"\"$AUB_TEST_INTERACTIVE_STARTED\" = yes ]] || exit 1\nprintf '%s\\n' "
        @"\"$CODEX_HOME\" "
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
    NSString *segment = [@"" stringByPaddingToLength:220
                                          withString:@"x"
                                     startingAtIndex:0];
    home = [NSString
        stringWithFormat:@"%@/%@/%@/%@", home, segment, segment, segment];
    struct {
      NSString *configured;
      NSString *environment;
      NSString *expected;
    } homes[] = {
        {home, @"/other-account", home},
        {nil, @"/environment", @"/environment"},
        {@"", nil,
         [NSHomeDirectory() stringByAppendingPathComponent:@".codex"]},
        {@"~/account", @"/other-account",
         [NSHomeDirectory() stringByAppendingPathComponent:@"account"]},
        {nil, @"relative",
         [files.currentDirectoryPath
             stringByAppendingPathComponent:@"relative"]},
    };
    for (NSUInteger index = 0; index < sizeof(homes) / sizeof(homes[0]);
         index++) {
      if (![AUBCodexSignInHome(homes[index].configured,
                               homes[index].environment)
              isEqualToString:homes[index].expected]) {
        fprintf(stderr, "Codex home resolution failed for case %lu\n",
                (unsigned long)index);
        return 1;
      }
    }
    home = AUBCodexSignInHome(home, @"/other-account");
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
      if (![files setAttributes:@{
            NSFilePosixPermissions : @0700
          }
                   ofItemAtPath:path
                          error:&error])
        return 1;
      task.executableURL = [NSURL fileURLWithPath:path];
      task.environment = @{
        @"HOME" : root,
        @"ZDOTDIR" : root,
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
    puts("ProviderSignInTests: 8 checks passed");
  }
  return 0;
}
