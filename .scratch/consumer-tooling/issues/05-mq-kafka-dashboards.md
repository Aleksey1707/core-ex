# 05: Дашборды `mq` и `kafka`

**What to build:** приложение выгружает дашборды подсистем библиотеки RabbitMQ Stream с
подписчиками (`mq`) и Kafka с DLQ (`kafka`). Набор по умолчанию учитывает опции
`Core.Mq.PromEx`: без `kafka_readers:` нет дашборда `kafka`, без `stream_readers:` и `readers:` —
нет `mq`. Основа — дашборды потребителя A без панели собственного плагина приложения
(`research.md`, раздел 1). Спека: `.scratch/consumer-tooling/spec.md`.

**Blocked by:** 01, 03

**Status:** ready-for-agent

- [ ] Шаблоны `mq` и `kafka` в `priv`, литералы под приложение — параметры
- [ ] Набор по умолчанию по опциям `Core.Mq.PromEx`; тесты на наличие и отсутствие каждого
- [ ] Самопроверка: имена метрик объявлены `Core.Mq.PromEx`, форма панелей проходит
- [ ] `README.md`: в примере `plugins/0` у `Core.Mq.PromEx` — `dlq_repo:`
- [ ] Пункт в CHANGELOG дополнен
- [ ] `make` зелёный
