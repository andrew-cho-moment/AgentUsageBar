#import "ProviderSignIn.h"

static NSString *AUBShellQuote(NSString *value) {
  return [NSString
      stringWithFormat:@"'%@'",
                       [value stringByReplacingOccurrencesOfString:@"'"
                                                        withString:@"'\\''"]];
}

NSString *AUBProviderSignInScript(AUBProviderKind provider, NSString *home) {
  NSString *command;
  switch (provider) {
  case AUBProviderKindClaude:
    // The fetcher reads Claude's standard Keychain service, even with a home
    // override.
    command = @"unset CLAUDE_CONFIG_DIR\nclaude auth login --claudeai";
    break;
  case AUBProviderKindCodex:
    command = [NSString stringWithFormat:@"export CODEX_HOME=%@\ncodex login",
                                         AUBShellQuote(home)];
    break;
  case AUBProviderKindCursor:
    return nil;
  }
  return [NSString
      stringWithFormat:
          @"#!/bin/zsh -l\n"
           "rm -- \"$0\"\nrmdir -- \"${0:h}\"\n"
           "export "
           "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"\n"
           "%@\n",
          command];
}
