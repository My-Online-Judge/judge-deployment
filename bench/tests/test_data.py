"""The bench problems' test data and reference solutions agree (spec §4.3)."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

DATA = Path(__file__).resolve().parent.parent / "data"
M = 1_000_000_007
REQUIRED = {"title", "subject", "timeLimit", "memoryLimit", "hardnessLevel", "problemSlug", "inputDescription",
            "outputDescription", "sampleInput", "sampleOutput", "status"}


def problems():
    return json.loads((DATA / "problems.json").read_text())


def cases(slug):
    return [(DATA / slug / f"{i}.in", DATA / slug / f"{i}.out") for i in range(1, 6)]


def test_two_problems_with_every_required_field_five_cases_and_both_solutions():
    ps = problems()
    assert [p["problemSlug"] for p in ps] == ["bench-ab", "bench-sum"]
    for p in ps:
        assert REQUIRED <= set(p), p["problemSlug"]
        assert p["status"] == 1  # ACTIVE, so it can be judged
        for i, o in cases(p["problemSlug"]):
            assert i.is_file() and o.is_file(), i
    for name in ("ab.cpp", "ab.py", "sum.cpp", "sum.py"):
        assert (DATA / "solutions" / name).is_file(), name


@pytest.mark.parametrize("slug,solution", [("bench-ab", "ab.py"), ("bench-sum", "sum.py")])
def test_the_python_solution_prints_every_expected_output(slug, solution):
    for i, o in cases(slug):
        with i.open() as stdin:
            got = subprocess.run([sys.executable, str(DATA / "solutions" / solution)], stdin=stdin,
                                 capture_output=True, text=True, check=True).stdout
        assert got.strip() == o.read_text().strip(), i.name


def test_bench_sum_outputs_match_the_closed_form():
    for i, o in cases("bench-sum"):
        n = int(i.read_text())
        assert int(o.read_text()) == n * (n + 1) * (2 * n + 1) // 6 % M


def test_bench_sum_is_moderate_work_for_python():
    assert [int(i.read_text()) for i, _ in cases("bench-sum")] == [1_000_000, 1_500_000, 2_000_000, 2_500_000, 3_000_000]


def test_the_samples_are_consistent():
    ab, s = problems()
    a, b = map(int, ab["sampleInput"].split())
    assert int(ab["sampleOutput"]) == a + b
    n = int(s["sampleInput"])
    assert int(s["sampleOutput"]) == n * (n + 1) * (2 * n + 1) // 6 % M
