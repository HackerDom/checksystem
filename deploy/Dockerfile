FROM node:12 as scoreboard

RUN git clone https://github.com/HackerDom/ctf-scoreboard-client.git /repo
WORKDIR /repo/scoreboard

RUN npm install
RUN npm run build

FROM ghcr.io/hackerdom/checksystem:master

COPY --from=scoreboard /repo/scoreboard/build /scoreboard
ENV CS_STATIC=/scoreboard

# Install checker's dependencies for current CTF.
# For example, you can use Gornilo library for simple
# way to write checkers (https://github.com/HackerDom/Gornilo)

RUN apt-get update
RUN apt-get install -y python3-pip
RUN pip install gornilo

# Copy checkers to /app/checkers catalog
# COPY checkers /app/checker
