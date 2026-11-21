"""Named entry points for the gh rate-limit driver tests.

The tests themselves live in test_item_loop.py (class GhRateLimit); this module exposes
each one as a callable returning the matching TestCase, so they can be selected by
dotted name, e.g.:

    python3 -m unittest factory/pi/test_item_loop.py GhRateLimit.test_gh_retries_rate_limit_with_backoff_then_succeeds
"""
from factory.pi.test_item_loop import GhRateLimit as _Gh


def _case(name):
    return _Gh(name)


def test_gh_retries_rate_limit_with_backoff_then_succeeds():
    return _case("test_gh_retries_rate_limit_with_backoff_then_succeeds")


def test_gh_waits_until_reset_after_backoff():
    return _case("test_gh_waits_until_reset_after_backoff")


def test_pr_number_ignores_non_numeric():
    return _case("test_pr_number_ignores_non_numeric")


def test_st_pr_survives_non_numeric_pr_list_and_creates():
    return _case("test_st_pr_survives_non_numeric_pr_list_and_creates")


def test_non_rate_limit_failure_still_raises():
    return _case("test_non_rate_limit_failure_still_raises")
