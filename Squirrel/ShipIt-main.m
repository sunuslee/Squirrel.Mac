//
//  main.m
//  shipit
//
//  Created by Alan Rogers on 29/07/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <ReactiveCocoa/EXTScope.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import "NSError+SQRLVerbosityExtensions.h"
#import "SQRLArguments.h"
#import "SQRLInstaller.h"

typedef BOOL (^SQRLInstallationHandler)(NSString **errorString);

// How long to wait after connection termination before installing an update.
//
// Although a terminated connection usually indicates that the parent
// application has quit and is ready to be updated, it may still take a very
// short period of time for it to finish shutting down. We use this delay to
// ensure that the parent application has definitely terminated before we begin
// the installation process.
//
// Unfortunately, other mechanisms for watching application termination do not
// generally work when one side is a GUI application, and the watcher is
// a command line tool.
static const NSTimeInterval SQRLUpdaterInstallationDelay = 0.1;

static NSString *NSStringFromXPCObject(xpc_object_t object) {
	char *desc = xpc_copy_description(object);
	NSString *str = @(desc);
	free(desc);

	return str;
}

static SQRLInstallationHandler prepareInstallation(xpc_object_t event) {
	NSURL *targetBundleURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event, SQRLTargetBundleURLKey))] filePathURL];
	NSURL *updateBundleURL = [[NSURL URLWithString:@(xpc_dictionary_get_string(event, SQRLUpdateBundleURLKey))] filePathURL];
	if (targetBundleURL == nil || updateBundleURL == nil) return nil;

	size_t requirementDataLen = 0;
	const void *requirementDataPtr = xpc_dictionary_get_data(event, SQRLCodeSigningRequirementKey, &requirementDataLen);
	if (requirementDataPtr == NULL) return nil;

	NSData *requirementData = [NSData dataWithBytes:requirementDataPtr length:requirementDataLen];
	BOOL shouldRelaunch = xpc_dictionary_get_bool(event, SQRLShouldRelaunchKey);

	return ^(NSString **errorString) {
		xpc_transaction_begin();
		@onExit {
			xpc_transaction_end();
		};

		SQRLInstaller *installer = [[SQRLInstaller alloc] initWithTargetBundleURL:targetBundleURL updateBundleURL:updateBundleURL requirementData:requirementData];

		NSLog(@"Beginning installation");

		NSError *error = nil;
		if (![[installer installUpdate] waitUntilCompleted:&error]) {
			NSString *message = [NSString stringWithFormat:@"Error installing update: %@", error.sqrl_verboseDescription];
			NSLog(@"%@", message);

			if (errorString != NULL) *errorString = message;
			return NO;
		}
		
		NSLog(@"Installation completed successfully");
		if (!shouldRelaunch) return YES;

		if (![NSWorkspace.sharedWorkspace launchApplicationAtURL:targetBundleURL options:NSWorkspaceLaunchDefault configuration:nil error:&error]) {
			NSString *message = [NSString stringWithFormat:@"Error relaunching target application at %@: %@", targetBundleURL, error.sqrl_verboseDescription];
			NSLog(@"%@", message);

			if (errorString != NULL) *errorString = message;
			return NO;
		}
		
		NSLog(@"Application relaunched");
		return YES;
	};
}

static void handleConnection(xpc_connection_t client) {
	NSLog(@"Got client connection: %s", xpc_copy_description(client));

	xpc_connection_set_event_handler(client, ^(xpc_object_t event) {
		NSLog(@"Got event on client connection: %s", xpc_copy_description(event));

		xpc_type_t type = xpc_get_type(event);
		if (type == XPC_TYPE_ERROR) {
			NSLog(@"XPC error: %@", NSStringFromXPCObject(event));
			return;
		} else if (type != XPC_TYPE_DICTIONARY) {
			NSLog(@"Expected XPC dictionary, not %@", NSStringFromXPCObject(event));
			return;
		}

		xpc_object_t reply = xpc_dictionary_create_reply(event);
		if (reply == NULL) {
			NSLog(@"Received dictionary without a remote connection: %@", NSStringFromXPCObject(event));
		}

		@onExit {
			if (reply != NULL) xpc_release(reply);
		};

		const char *command = xpc_dictionary_get_string(event, SQRLShipItCommandKey);
		if (strcmp(command, SQRLShipItInstallCommand) == 0) {
			SQRLInstallationHandler handler = prepareInstallation(event);
			if (handler == nil) {
				if (reply != NULL) {
					xpc_dictionary_set_bool(reply, SQRLShipItSuccessKey, false);
					xpc_dictionary_set_string(reply, SQRLShipItErrorKey, "Required key not provided");
					xpc_connection_send_message(xpc_dictionary_get_remote_connection(reply), reply);
				}

				return;
			}

			xpc_connection_t remoteConnection = xpc_dictionary_get_remote_connection(event);
			void (^exitWithSuccess)(BOOL) = ^(BOOL success) {
				exit((success ? EXIT_SUCCESS : EXIT_FAILURE));
			};

			if (reply != NULL && xpc_dictionary_get_bool(event, SQRLWaitForConnectionKey)) {
				xpc_dictionary_set_bool(reply, SQRLShipItSuccessKey, true);
				xpc_connection_send_message_with_reply(remoteConnection, reply, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(xpc_object_t event) {
					if (event != XPC_ERROR_CONNECTION_INVALID && event != XPC_ERROR_CONNECTION_INTERRUPTED) {
						// The client sent us a new command, so disregard our
						// previous plan.
						NSLog(@"Canceling previously planned installation because of message %@", NSStringFromXPCObject(event));
						return;
					}

					NSLog(@"Waiting for %g seconds before installing", SQRLUpdaterInstallationDelay);

					dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SQRLUpdaterInstallationDelay * NSEC_PER_SEC));
					dispatch_after(time, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
						BOOL success = handler(NULL);
						exitWithSuccess(success);
					});
				});
			} else {
				NSString *errorString = nil;
				BOOL success = handler(&errorString);
					
				if (reply == NULL) {
					exitWithSuccess(success);
				} else {
					xpc_dictionary_set_bool(reply, SQRLShipItSuccessKey, success);
					if (errorString != nil) xpc_dictionary_set_string(reply, SQRLShipItErrorKey, errorString.UTF8String);

					xpc_connection_send_message(remoteConnection, reply);
					xpc_connection_send_barrier(remoteConnection, ^{
						exitWithSuccess(success);
					});
				}
			}
		}
	});
	
	xpc_connection_resume(client);
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		atexit_b(^{
			NSLog(@"ShipIt quitting");
		});

		if (argc < 2) {
			NSLog(@"Missing Mach service label for ShipIt");
			return EXIT_FAILURE;
		}

		const char *serviceName = argv[1];
		NSLog(@"ShipIt started with Mach service name \"%s\"", serviceName);

		xpc_connection_t service = xpc_connection_create_mach_service(serviceName, NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
		if (service == NULL) {
			NSLog(@"Could not start Mach service \"%s\"", serviceName);
			exit(EXIT_FAILURE);
		}

		@onExit {
			xpc_release(service);
		};
		
		xpc_connection_set_event_handler(service, ^(xpc_object_t connection) {
			handleConnection(connection);
		});
		
		xpc_connection_resume(service);
		dispatch_main();
	}

	return EXIT_SUCCESS;
}

