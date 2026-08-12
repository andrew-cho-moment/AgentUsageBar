#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>

enum { AUBMaximumCredentialBytes = 64 * 1024 };

typedef enum {
  AUBCredentialExitSuccess,
  AUBCredentialExitFailure,
  AUBCredentialExitUsage,
  AUBCredentialExitNotFound,
} AUBCredentialExit;

static bool AUBWriteAll(const void *buffer, size_t length) {
  const uint8_t *bytes = buffer;
  size_t written = 0;
  while (written < length) {
    ssize_t count = write(STDOUT_FILENO, bytes + written, length - written);
    if (count > 0) {
      written += (size_t)count;
      continue;
    }
    if (count < 0 && errno == EINTR)
      continue;
    return false;
  }
  return true;
}

int main(int argc, const char *argv[]) {
  (void)argv;
  if (argc != 1)
    return AUBCredentialExitUsage;

  const void *keys[] = {
      kSecClass,
      kSecAttrService,
      kSecReturnData,
      kSecMatchLimit,
  };
  const void *values[] = {
      kSecClassGenericPassword,
      CFSTR("Claude Code-credentials"),
      kCFBooleanTrue,
      kSecMatchLimitOne,
  };
  CFDictionaryRef query = CFDictionaryCreate(
      kCFAllocatorDefault, keys, values, sizeof(keys) / sizeof(keys[0]),
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  if (query == NULL)
    return AUBCredentialExitFailure;

  CFTypeRef item = NULL;
  OSStatus status = SecItemCopyMatching(query, &item);
  CFRelease(query);
  if (status == errSecItemNotFound)
    return AUBCredentialExitNotFound;
  if (status != errSecSuccess || item == NULL ||
      CFGetTypeID(item) != CFDataGetTypeID()) {
    if (item != NULL)
      CFRelease(item);
    return AUBCredentialExitFailure;
  }

  CFDataRef data = item;
  CFIndex length = CFDataGetLength(data);
  bool valid = length > 0 && length <= AUBMaximumCredentialBytes;
  bool written = valid && AUBWriteAll(CFDataGetBytePtr(data), (size_t)length);
  CFRelease(data);
  return written ? AUBCredentialExitSuccess : AUBCredentialExitFailure;
}
