# The analysis environment of the bench (sub-project 5): every package pinned (requirements.txt, frozen from the
# first build; pyparsing held at 3.1.4, before the deprecations matplotlib 3.9.2 trips over), so a chart re-made
# later is the same chart.
FROM python:3.11-slim
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
ENV PYTHONPATH=/bench/analyze MPLCONFIGDIR=/tmp/mpl PYTHONDONTWRITEBYTECODE=1
