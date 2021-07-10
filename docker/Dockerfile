FROM perl

ADD cpanfile /

RUN cpanm -n --installdeps /
RUN cpanm -n DDP

RUN apt-get update && apt-get install -y less

WORKDIR /app
COPY . /app

CMD ["/bin/bash"]
