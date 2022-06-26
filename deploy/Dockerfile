FROM ghcr.io/hackerdom/checksystem:master

# Install checker's dependencies for current CTF.
# For example, you can use Gornilo library for simple
# way to write checkers (https://github.com/HackerDom/Gornilo)

RUN apt-get update
RUN apt-get install -y python3-pip
RUN pip install gornilo

# Copy checkers to /app/checkers catalog
# COPY checkers /app/checker
