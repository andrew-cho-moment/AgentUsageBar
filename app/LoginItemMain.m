#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 2)
      return 2;

    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    if (strcmp(argv[1], "--enable") == 0) {
      if (service.status != SMAppServiceStatusEnabled &&
          service.status != SMAppServiceStatusRequiresApproval &&
          ![service registerAndReturnError:&error]) {
        return 1;
      }
      return 0;
    }
    if (strcmp(argv[1], "--disable") == 0) {
      if (service.status != SMAppServiceStatusNotRegistered &&
          ![service unregisterAndReturnError:&error]) {
        return 1;
      }
      return 0;
    }
    return 2;
  }
}
