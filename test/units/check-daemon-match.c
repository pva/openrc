/*
 * Test matching daemon records without sharing partial matches between
 * different files.
 */

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "rc.h"

static char test_root[PATH_MAX];
static int failures;

static void
fail(const char *message)
{
	fprintf(stderr, "FAIL: %s\n", message);
	failures++;
}

static void
fatal(const char *message)
{
	perror(message);
	exit(EXIT_FAILURE);
}

static void
make_path(char *path, size_t size, const char *service, const char *instance)
{
	int len;

	if (instance)
		len = snprintf(path, size, "%s/daemons/%s/%s",
		    test_root, service, instance);
	else if (service)
		len = snprintf(path, size, "%s/daemons/%s", test_root, service);
	else
		len = snprintf(path, size, "%s/daemons", test_root);

	if (len < 0 || (size_t)len >= size) {
		fprintf(stderr, "test path is too long\n");
		exit(EXIT_FAILURE);
	}
}

static void
make_service_dir(const char *service)
{
	char path[PATH_MAX];

	make_path(path, sizeof(path), service, NULL);
	if (mkdir(path, 0700) == -1)
		fatal("mkdir service directory");
}

static void
write_daemon(const char *service, const char *instance, const char *contents)
{
	char path[PATH_MAX];
	FILE *fp;

	make_path(path, sizeof(path), service, instance);
	if (!(fp = fopen(path, "w")))
		fatal("fopen daemon record");
	if (fputs(contents, fp) == EOF || fclose(fp) == EOF)
		fatal("write daemon record");
}

static size_t
count_daemons(const char *service)
{
	char path[PATH_MAX];
	struct dirent *d;
	size_t count = 0;
	DIR *dp;

	make_path(path, sizeof(path), service, NULL);
	if (!(dp = opendir(path)))
		fatal("opendir service directory");

	while ((d = readdir(dp)))
		if (d->d_name[0] != '.')
			count++;
	closedir(dp);
	return count;
}

static void
cleanup_service(const char *service)
{
	char path[PATH_MAX];
	char file[PATH_MAX];
	struct dirent *d;
	DIR *dp;

	make_path(path, sizeof(path), service, NULL);
	if (!(dp = opendir(path)))
		return;

	while ((d = readdir(dp))) {
		if (d->d_name[0] == '.')
			continue;
		make_path(file, sizeof(file), service, d->d_name);
		unlink(file);
	}
	closedir(dp);
	rmdir(path);
}

static void
test_started_daemon(void)
{
	const char *argv[] = { "--wanted", NULL };

	make_service_dir("started-partial");
	write_daemon("started-partial", "001",
	    "exec=/usr/bin/wanted\n"
	    "argv_0=--other\n"
	    "pidfile=\n");
	write_daemon("started-partial", "002",
	    "exec=/usr/bin/other\n"
	    "argv_0=--wanted\n"
	    "pidfile=\n");

	if (rc_service_started_daemon("started-partial",
	    "/usr/bin/wanted", argv, 0))
		fail("partial matches from separate files were combined");

	make_service_dir("started-exact");
	write_daemon("started-exact", "001",
	    "exec=/usr/bin/wanted\n"
	    "argv_0=--wanted\n"
	    "pidfile=\n");

	if (!rc_service_started_daemon("started-exact",
	    "/usr/bin/wanted", argv, 0))
		fail("an exact daemon record did not match");
}

static void
test_daemon_set(void)
{
	make_service_dir("set-partial");
	write_daemon("set-partial", "001",
	    "exec=/usr/bin/wanted\n"
	    "pidfile=/run/other.pid\n");
	write_daemon("set-partial", "002",
	    "exec=/usr/bin/other\n"
	    "pidfile=/run/wanted.pid\n");

	if (!rc_service_daemon_set("set-partial", "/usr/bin/wanted", NULL,
	    "/run/wanted.pid", false))
		fail("rc_service_daemon_set failed");
	if (count_daemons("set-partial") != 2)
		fail("a daemon record matching only part of the criteria was removed");

	make_service_dir("set-exact");
	write_daemon("set-exact", "001",
	    "exec=/usr/bin/wanted\n"
	    "pidfile=/run/wanted.pid\n");

	if (!rc_service_daemon_set("set-exact", "/usr/bin/wanted", NULL,
	    "/run/wanted.pid", false))
		fail("rc_service_daemon_set failed for an exact match");
	if (count_daemons("set-exact") != 0)
		fail("an exactly matching daemon record was not removed");
}

static void
setup(void)
{
	const char *build_root;
	char path[PATH_MAX];
	int len;

	build_root = getenv("BUILD_ROOT");
	if (!build_root)
		build_root = "/tmp";

	len = snprintf(test_root, sizeof(test_root),
	    "%s/tmp-check-daemon-match.XXXXXX", build_root);
	if (len < 0 || (size_t)len >= sizeof(test_root)) {
		fprintf(stderr, "test path is too long\n");
		exit(EXIT_FAILURE);
	}
	if (!mkdtemp(test_root))
		fatal("mkdtemp");
	if (setenv("RC_SVCDIR", test_root, 1) == -1)
		fatal("setenv RC_SVCDIR");

	make_path(path, sizeof(path), NULL, NULL);
	if (mkdir(path, 0700) == -1)
		fatal("mkdir daemons directory");
}

static void
cleanup(void)
{
	char path[PATH_MAX];

	cleanup_service("started-partial");
	cleanup_service("started-exact");
	cleanup_service("set-partial");
	cleanup_service("set-exact");
	make_path(path, sizeof(path), NULL, NULL);
	rmdir(path);
	rmdir(test_root);
}

int
main(void)
{
	setup();
	test_started_daemon();
	test_daemon_set();
	cleanup();
	return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
