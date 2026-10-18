# Готовые решения: crypto-shredding в event sourcing

Исследование на 2026-10-18. Версии:

- Axon Data Protection: документация Axon Framework Reference 5.4, последний выпуск модуля в release notes — 5.2.
  Исходники модуля закрыты.
- KurrentDB: документация v26.0, `docs/` репозитория на `929bdd7` (последний выпуск — v26.2.2), пример
  `kurrent-io/samples` на `fb9bbf5`.
- akka-gdpr: документация линейки 1.1 (артефакт 1.1.16).
- Marten master `2ece3a9` (`V9.50.3`).
- Eventuous master `60a7643`, документация `eventuous-docs` `4989283`.
- Commanded `v1.4.11` (`936dbb1`), commanded/eventstore master `49ba9f9`.
- cloak master `9a3d10c` (hex 1.1.4), cloak_ecto master `9989e73` (hex 1.3.0).

«Вывод из кода» — следствие из прочитанного кода, которого нет в тексте источника. «Вывод» — следствие из
документации или из сопоставления источников. Правовая оценка по 152-ФЗ — в тикете 01, шифры и формат шифротекста
`:core` — в тикете 03; здесь они не повторяются.

## Вопрос

[Тикет](../issues/02-research-crypto-shredding-prior-art.md): как crypto-shredding устроен в готовых ES-системах и
библиотеках. Пункты вопроса:

- единица ключа и связь субъекта с событием;
- слой шифрования и что видит апкастер;
- что получает читатель после уничтожения ключа и как это переживают свёртка, проекции и чтение истории;
- хранилище ключей;
- судьба снапшотов, read-моделей, сообщений брокера, поиска и уникальности по ПДн;
- подтверждение уничтожения и аудит.

## Паттерн: Mathias Verraes

**Crypto-Shredding** (2019-05-13) [1]. Проблема — та же, что у Forgettable Payloads: часть атрибутов события не
должна читаться всеми потребителями, и её нужно уметь удалить, не трогая event store. Решение: шифровать
чувствительные атрибуты «отдельным ключом для каждого ресурса (например, клиента)» и выдавать ключ только тем
потребителям, которым он нужен. Чтобы стереть данные, удаляют ключ — тогда непригодными становятся все копии и бэкапы.

- Паттерн надёжен ровно настолько, насколько надёжны шифр и практика управления ключами.
- Если проекции тоже хранят ПДн зашифрованными, удаление дешёвое. Того же даёт Forgettable Payloads. Ни один из двух
  паттернов не решает случай, когда потребитель хранит расшифрованное значение или вычисляет из него новое.
- В дополнении к статье (ответ Harrison J. Brown): по GDPR зашифрованные ПДн остаются ПДн, и удаление ключа не равно
  удалению данных. Для ПДн автор ответа считает уместнее Forgettable Payloads.

**Forgettable Payloads** (2019-05-13) [2] — альтернатива без шифрования:

- ПДн выносятся из события в отдельное (логическое) хранилище, а событие несёт ссылку на запись.
- По запросу на удаление нагрузку удаляют, события остаются нетронутыми. Потребитель, запросивший удалённую
  нагрузку, показывает пустое значение.
- Вместо удаления можно подставить «John Doe». Пример из статьи: `organisation: "(removed under GDPR removal request
  #456)"`, `birthday: null`.
- Слабости:
  - отдельное хранилище ломает «единственный источник истины», и после каждого события потребитель идёт за нагрузкой;
  - у потребителей остаются локальные копии; выход — производитель публикует `GDPRDeletionWasRequested {customerId}`,
    и потребители на него реагируют;
  - связи с другими данными продолжают указывать на человека.

## Axon Data Protection (AxonIQ)

Коммерческий модуль Axon Framework, прежнее название — «GDPR Module». Для промышленной эксплуатации нужна
лицензия [3][8]. Исходники не опубликованы: репозитория модуля в организации AxonIQ на GitHub нет [14], поэтому
ниже описана только документация. Модуль работает и без Axon Framework [12], и без Axon Server [13].

**Единица ключа.** Ключ задаёт поле `@DataSubjectId` [4]:

- идентификатор ключа — `prefix` плюс `toString()` значения поля; `null` в поле при шифровании даёт исключение;
- атрибут `group` даёт несколько ключей в одном объекте и позволяет стирать поля выборочно — например, отдельно имя и
  адрес. Одно поле id с разными `prefix` даёт ключи `name-913` и `address-913`;
- вложенный объект под `@DeepPersonalData` наследует субъект из контекста обхода и может переопределить его своим
  `@DataSubjectId`; у `Map` субъектом может быть ключ записи (`scope = KEY`).

Если подходящего поля в объекте нет, идентификатор ключа передаётся в вызов: `FieldEncrypter.encrypt(object, keyId)`.
Это «preset encryption context» — например, для системного ключа [5].

**Слой.** `FieldEncrypter` шифрует поля прямо в объекте [4]:

- `@PersonalData` сохраняет тип: шифротекст кладётся в то же поле. Поддерживаются `String`, `byte[]` и, рекурсивно,
  коллекции и `Map` из них;
- `@SerializedPersonalData` — для остальных типов: значение сериализуется, шифруется и кладётся в отдельное поле
  `<имя>Encrypted` (`String` / `byte[]`). Цена — лишнее поле и затраты CPU;
- у коллекции под `@PersonalData` шифруются элементы, а их число остаётся открытым. `@SerializedPersonalData`
  скрывает и число, хотя длина шифротекста всё ещё о нём говорит.

`FieldEncryptingConverter` оборачивает конвертер-делегат; в AF 4.x его роль играл `FieldEncryptingSerializer` [5][10]:

- на записи он сначала шифрует, потом конвертирует, на чтении — наоборот;
- автоконфигурация строит из него конвертеры сообщений и событий, и события лежат в store зашифрованными [5];
- тот же конвертер обрабатывает payload команд и запросов, события store, снапшоты и события persistent stream [9].

Шифрование идемпотентно: зашифрованное поле повторно не шифруется, а расшифровка открытого поля его не меняет. Оно
также null-safe. Поэтому store может хранить смесь зашифрованных и открытых данных [4][5]. На этом строится перевод
существующей истории: либо перешифровка с простоем, либо сериализатор, который различает два вида событий [13].
Шифр — AES, длина ключа по умолчанию — 256 бит [12].

Что видит апкастер, документация модуля не говорит. Апкастеры AF 4.x работают над `IntermediateEventRepresentation` —
сериализованным событием до десериализации [11]. Вывод: расшифровка идёт после делегата, поэтому ПДн-поля апкастер
видит шифротекстом.

**После уничтожения ключа.** Расшифровка без ключа подставляет значение из `ReplacementValueProvider` [7]:

- по умолчанию: для `String` — атрибут `replacement` аннотации (по умолчанию пустая строка), для прочих типов —
  `null`, для примитивов — значение по умолчанию Java [4][7]. Пример из блога: `street` → `"replacementValue"`,
  `city` → `""`, `houseNumber` → `0`, `houseNumberEncrypted` → `null` [12];
- свой провайдер переопределяет `replacementValue`. Метод `partialValueForStorage` при шифровании сохраняет рядом с
  шифротекстом открытую часть — год даты рождения или последние 4 цифры карты, — и она доступна при замене [7];
- вызов `replace` сразу, без шифрования, заменяет открытое значение тем, что осталось бы после стирания [5].

Ошибки бывают двух видов, оба с кодами `ADPM-xxxx` [7]:

- `ConfigurationException` — ошибка кода или платформы, исправить её в работе нельзя;
- `DataException` — сбой одной записи, его можно ловить.

Вывод: свёртка агрегата, проекции и чтение истории получают обычный объект с подставленными значениями. Стёртое поле
по такому объекту не отличить от пустой строки, если для `replacement` не выбрано особое значение.

**Ключи.** `CryptoEngine` умеет [6]:

- получить ключ;
- получить ключ или создать его;
- удалить ключ;
- выдать `Cipher`;
- сменить длину новых ключей.

Приложение вызывает только удаление, остальное вызывает `FieldEncrypter`. Ключи и `Cipher` связаны в одном интерфейсе
ради HSM, где ключ не покидает устройство. Реализации [6]:

- `InMemoryCryptoEngine` — только для тестов;
- `JpaCryptoEngine` / `JdbcCryptoEngine` — таблица `axoniq_gdpr_keys (key_id VARCHAR(255) PRIMARY KEY, secret_key
  TEXT NOT NULL)` в реляционной БД, транзакции у движка свои;
- `VaultCryptoEngine` — HashiCorp Vault. Ключи в нём шифрует master key Vault; в enterprise-версии master key может
  приходить из HSM, AWS KMS или Google KMS. По документации политика доступа обязана разрешать `create`, `read` и
  `delete`, но не `update` — иначе гонка перезапишет ключ. Токен Vault обновляет приложение;
- `JavaKeyStoreCryptoEngine` и `PKCS11CryptoEngine` (HSM).

Гонка «получить или создать»: два процесса одновременно создают ключ, второй перезаписывает первый, и данные под
первым ключом теряются. JPA/JDBC и Vault от неё защищены и годятся для нескольких узлов; JavaKeyStore и PKCS#11 —
нет [6]. Кеш ключей в документации не описан. При мультитенантности нужен отдельный конвертер и `CryptoEngine` на
каждого тенанта: общий engine при совпадающих id субъектов изоляции не даёт [9].

**Снапшоты, read-модели, поиск.** Снапшоты проходят через тот же конвертер [9]. Для query handlers документация
предлагает бин `FieldEncrypter` для ручной расшифровки [5]. Поиск и уникальность по зашифрованному полю не описаны.

**Подтверждение и аудит.** Ключ удаляет `cryptoEngine.deleteKey(dataSubjectId)`: данные остаются в событиях, но не
расшифровываются [6]. Отчёта или события о стирании модуль не описывает. На вопрос, достаточен ли crypto-shredding,
сотрудник AxonIQ отвечает, что это зависит от страны и что, например, в Германии его недостаточно [13].

## Kurrent (EventStoreDB / KurrentDB)

**Официальная документация.** О crypto-shredding в документации сервера ничего нет. Для удаления данных она предлагает
три шага: переписать поток в новый без этих данных, удалить старый поток, запустить scavenge на каждом узле [18].

- До scavenge удалённые события остаются в `$all`; scavenge необратим [19].
- При положительном пороге scavenge часть удалённых событий остаётся — документация отмечает, что это важно для
  GDPR [19].
- Если такой путь непрактичен, есть redaction [18]:
  - нужна лицензия, инструмент выдают по запросу, документация называет его «last resort»;
  - данные события забиваются байтами `0xFF` того же размера, на записи ставится флаг `IsRedacted`;
  - тип, метаданные и время события не меняются;
  - запускается на каждом узле;
  - может дать «непредвиденные последствия» для подписок и проекций.
- Официальный skill Kurrent отсылает запрос «GDPR / right-to-be-forgotten» именно к redaction [20].

**Форум, ответ сотрудника Event Store от 2020-12-10** [21]:

- отдельные потоки для ПДн — один из способов;
- событие удаления плюс truncate потока уберут ПДн при следующем scavenge и одновременно сообщат проекциям, что нужно
  удалить read-модели с ПДн этого человека;
- crypto-shredding — «другой способ»; статья о нём тогда готовилась.

**Блог Kurrent, 2021-08-12** [15]. Статью написал сторонний автор (Diego Martin; в подписи — основатель Sunny Attic
Software). Пример — на .NET с gRPC-клиентом EventStoreDB, код лежит в `kurrent-io/samples` [16]. На 2026-10-18
исходный URL перенаправляет на главную блога, поэтому текст читался по копии Wayback Machine от 2026-04-14.

- Единица ключа — субъект. `[DataSubjectId]` ставится на поле события (в примере — `PersonId`), `[PersonalData]` —
  на шифруемые поля, включая вложенный `Address`. Значение `[DataSubjectId]` копируется в метаданные события
  (`dataSubjectId`) [15].
- Слой — сериализатор. Contract resolver Newtonsoft вешает на поля `[PersonalData]` конвертер: тот приводит значение к
  строке, шифрует, кодирует в base64 и добавляет префикс `crypto.` [15].
- Чтение [15]:
  - десериализатор берёт `dataSubjectId` из метаданных и расшифровывает строки с префиксом `crypto.`;
  - без ключа строка становится `"***"`, а другие типы — значением по умолчанию (0, `DateTime.MinValue`);
  - по префиксу можно десериализовать событие в другой класс с теми же ключами JSON; автор связывает это с
    версионированием по «слабой схеме»;
  - в тесте у субъекта с удалённым ключом `Name == "***"` и `Birthday == default`, а `CountryCode` без атрибута
    остаётся открытым.
- Ключи хранит `CryptoRepository` в памяти — `Dictionary` по data subject id. Запись вызывает `GetExistingOrNew`,
  чтение — `GetExistingOrDefault`, стирание — `DeleteEncryptionKey` [15][16].
- Шифр — `Aes.Create()` с `PKCS7`; ключ и IV генерируются один раз на субъекта и хранятся вместе [15][16]. Режим не
  задан, а у .NET по умолчанию это CBC [17]. Вывод из кода: все значения субъекта шифруются с одним IV, шифротекст не
  аутентифицирован, и равные значения одного субъекта дают равный шифротекст.
- Уже записанную историю статья предлагает перенести по схеме «copy and replace»: перечитать события, записать их
  зашифрованными в новый store, пересобрать read-модели и удалить старый store [15].
- Снапшоты, брокер, поиск и подтверждение уничтожения статья не рассматривает.

## Akka Persistence: akka-gdpr (Lightbend)

Модуль входит в подписку Lightbend Platform. Статус — «May Change», но формат сериализации обещан стабильным [22].
Документация относится к линейке Akka Enhancements 1.1 (`akka-gdpr` 1.1.16) [24]. В оглавлении текущей Akka
Enhancements 2.0.0 GDPR-модуля нет [27].

**Единица ключа** — data subject id [22].

- Событие или его часть оборачивается в `WithDataSubjectId(dataSubjectId, payload)` [24].
- Если в событии несколько субъектов (чаще так бывает со снапшотом), нужен свой сериализатор: каждая часть
  `WithDataSubjectId` превращается в байты утилитой `WithDataSubjectIdSerialization` [24].
- Советы по id субъекта [26]:
  - id сам не должен быть ПДн — никнейм не подходит;
  - подходит UUID или SHA-1 от user id с секретной солью;
  - id можно строить от `persistenceId` — документация называет это «простым и действенным решением»;
  - у одного человека в разных системах бывает несколько id.

**Слой** — сериализатор `GdprSerializer`, привязанный к `WithDataSubjectId` [24]:

- событие сериализуется обычной сериализацией Akka;
- нагрузка шифруется AES-GCM без padding;
- IV берётся из `SecureRandom` для каждой нагрузки, длина IV равна длине ключа, IV кладётся в начало шифротекста;
- результат — protobuf `WithDataSubjectId { dataSubjectId, payload, serializerId, manifest }`.

Вывод: id субъекта лежит в конверте открыто, и шифруется событие целиком, а не отдельное поле.

**После уничтожения ключа** `payload` десериализуется как `None` (в Java — `Optional.empty()`). По документации это
значение «нужно учитывать при воспроизведении и обработке событий» [24]. Пример: сущность поста знает, что если
автор комментария не расшифровывается, автора не показывают [23].

**Ключи** [25]:

- расширение `GdprEncryption` (`encrypt`, `decrypt`, `shred`) или `AbstractGdprEncryption` с `KeyManagement`
  (`shred`, `getOrCreateKey`, `getKey`, который после shred возвращает `None`);
- размер ключа задаёт `akka.persistence.gdpr.key-size`; реализации обязаны быть потокобезопасными;
- `JavaKeyStoreGdprEncryption` (PKCS12 / JCEKS) работает только на одном узле: ключи лежат в файле без избыточности,
  и порча хранилища означает потерю всех данных;
- для кластера нужна своя `KeyManagement` над распределённым хранилищем, например Vault;
- `TestGdprEncryption` держит ключи в памяти для тестов [24].

**Где ещё живут ПДн** (раздел «Shred or delete?») [23]:

- удаление событий и снапшотов не достаёт денормализованные копии, например tagged-представление в плагине
  Cassandra. Поэтому все события и снапшоты сущности шифруются ключом пользователя;
- состояние в памяти: сущность держит ПДн до пассивации, поэтому рекомендована периодическая пассивация с
  восстановлением. GDPR не требует забывать немедленно — достаточно периодического перезапуска или rolling upgrade;
- проекции — в два шага. Сначала публикуется событие «субъект удаляется», и read-side удаляет свои данные. Когда
  событие точно разошлось, фоновое задание удаляет ключ — например, через неделю. Этот порядок заодно решает
  проблему других ключей на read-side, событий в полёте и передачи удаления в другие сервисы через брокер;
- брокер: либо публиковать зашифрованное — тогда потребителям нужен общий доступ к ключам, и события могут стать
  нечитаемыми до обработки, — либо настроить retention. Retention удаляет данные дольше, но для GDPR это приемлемо и
  обычно проще;
- бэкапы: зашифрованные бэкапы проблемой не считаются; для открытых бэкапов и для бэкапов ключей нужен retention;
- логи: ПДн не логировать, старые логи удалять.

**Поиск по субъекту** — `eventsByTag` по тегу с id субъекта [22].

**Подтверждение.** Кроме завершения `shred` (`Future[Done]` / `CompletionStage<Done>`), подтверждения нет [24][25].
Нужно ли удалять метаданные, по которым восстанавливаются связи субъекта, — по документации, устоявшихся решений
по этому вопросу ещё нет [26].

## Marten

Crypto-shredding в Marten нет:

- врезка в документации говорит, что команда «как минимум рассматривает» его для Marten 8.0, но определённых планов
  нет [28];
- issue #3494 включал пункт «встроить crypto shredding в чтение событий». Ответ 2025-05-29 — «Not happening for 8.0»;
  2026-02-11 issue закрыт со словами «Nobody has ever asked for this» [30];
- в #2779 (запрос на анонимизацию) мейнтейнер ссылается на маскирование и на серию блог-постов участника команды о
  crypto shredding с Marten [30].

Вместо этого с версии 7.31 есть **маскирование** — по сути, переписывание истории [28][29]:

- правила задаются на тип события и регистрируются только при конфигурации: `Action<T>` правит объект, `Func<T,T>`
  заменяет его. Правило можно повесить и на интерфейс, общий для нескольких типов событий;
- `ApplyEventDataMasking` применяет правила к потоку, к отфильтрованным событиям потока, к LINQ-выборке по всему store
  или к тенанту. Можно добавить заголовок (например, `masked` с текущим временем), но только тем событиям, к которым
  подошло правило;
- реализация читает события, применяет к каждому все подошедшие правила и в одной сессии выполняет
  `UPDATE mt_events SET data = …[, headers = …] WHERE seq_id = …` [29];
- на архив событий и проекции маскирование не влияет, пока проекцию не пересоберут [28].

Цену изменяемой истории показывают ошибки самого механизма:

- #5199: применялось только первое подошедшее правило. Защищённые данные молча переживали маскирование, а операция
  сообщала об успехе [29][30];
- #5234: при `UseTenantPartitionedEvents` `UPDATE` по одному `seq_id` переписывал события с тем же номером у всех
  тенантов. Восстановить их можно только из бэкапа [28].

Вывод из кода: после маскирования свёртка и чтение истории видят обычные значения, которые задало правило (в примере —
`"****"`). Отличить их от исходных можно только по заголовку.

## Eventuous

Встроенного crypto-shredding нет: ни в коде, ни в документации нет совпадений по crypto, shred, encrypt, GDPR и PII
[31][32]. Открыт issue #221 (2023-05-26, без ответов) с предложением по образцу статьи из блога Kurrent [32]:

- атрибуты `[PersonalData]` / `[DataSubjectId]`;
- ключ из репозитория — AKS или в памяти;
- префикс-маркер шифротекста;
- id субъекта в метаданных;
- без ключа — значение по умолчанию или маска (`""`, `"***"`, `null`, 0, `false`).

Автор issue отмечает, что для этого своему `IEventSerializer` нужен доступ к метаданным.

Вывод из кода: доступа к метаданным у `IEventSerializer` нет [31]. `SerializeEvent(object evt)` возвращает тип,
content type и байты, а `DeserializeEvent(data, eventType, contentType)` получает только их. Метаданные добавляет
отдельный делегат `AmendEvent` при записи. Значит, шифрующий сериализатор может взять id субъекта только из самого
события.

## Commanded и EventStore (Elixir)

Встроенного механизма нет. Recipe-issue «GDPR compliance» (2019-11-28, открыт, автор — мейнтейнер) перечисляет три
варианта [33]:

- crypto-shredding: шифровать ПДн в событиях и «забыть» ключ;
- внешнее хранилище ПДн со ссылкой из события; при чтении удалённой записи возвращается «соответствующая ошибка»;
- изменяемые события или потоки — hard delete в EventStore.

В commanded/eventstore#269 (2023-05-18) мейнтейнер советует [34]:

- не трогать store из `execute/2` агрегата;
- делать hard delete потока обработчиком событий и затем дописывать событие удаления;
- либо использовать внешнее хранилище или crypto-shredding.

Hard delete в EventStore [34]:

- по умолчанию выключен и включается опцией `enable_hard_deletes: true`;
- необратим и удаляет события и из `$all`, и из связанных потоков;
- в удалённый поток можно снова писать — «как будто его не было»;
- документация называет GDPR одним из поводов для hard delete.

На уровне debug Commanded пишет команды в лог; чтобы скрыть поля, предложен `@derive {Inspect, only: [...]}` [35].
Пакетов crypto-shredding на hex.pm нет: поиск по shred, shredding, gdpr и pii ничего не нашёл [39].

## cloak и cloak_ecto (Elixir)

Это шифрование полей ради конфиденциальности, а не crypto-shredding: ключа на субъекта нет [36][37].

- **Ключи.** `use Cloak.Vault, otp_app:` создаёт GenServer, который хранит конфигурацию шифров в ETS-таблице
  `<Vault>.Config`; шифрование и расшифровка идут в процессе вызывающего [36]. `ciphers:` — список
  `{label, {Cipher, tag:, key:}}`. Новые данные шифруются первым шифром списка или шифром, названным `label` поля.
  Ключ можно получить в рантайме, в `init/1` (например, из переменной окружения) [36]. Вывод из кода: ключ выбирает
  конфигурация, а не данные записи, и для ключа на субъекта понадобился бы свой слой.
- **Формат** `Cloak.Ciphers.AES.GCM`: `key tag (TLV) | IV 16 байт | ciphertag 16 байт | шифротекст`. IV случайный для
  каждого шифрования, AAD — константа `"AES256GCM"` [36]. Вывод из кода: шифротекст не привязан ни к записи, ни к
  полю, и его можно перенести в другую строку.
- **Расшифровка** выбирает шифр по тегу (`can_decrypt?`) [36]:
  - если шифра с таким тегом нет — `{:error, %Cloak.MissingCipher{}}`, и `Cloak.Ecto.Type.load/1` возвращает
    `:error` [37];
  - вывод из кода, подтверждённый проверкой на OTP 29: при том же теге, но другом ключе
    `:crypto.crypto_one_time_aead/7` возвращает `error`, а шифр без проверки оборачивает его в `{:ok, :error}` [36][38].
- **Ротация** [37]:
  - новый ключ ставится первым в списке, а старый — ниже, под другим тегом;
  - `mix cloak.migrate.ecto` перешифровывает данные, после чего старый ключ удаляют;
  - без миграции данные переходят на новый ключ постепенно, по мере перезаписи.
- **Поиск** [37]:
  - `Cloak.Ecto.HMAC` хранит детерминированный HMAC в отдельной колонке (`email_hash`), и запрос по ней заменяет
    запрос по зашифрованному полю;
  - документация предупреждает, что равные значения видны по равным хешам, а HMAC с секретом надёжнее `SHA256`;
  - `closure: true` оборачивает расшифрованное значение в нуль-арную функцию, чтобы оно случайно не утекло в логи.

## Сравнение

| Пункт | Решение | Как устроено |
|---|---|---|
| Единица ключа, связь с событием | Verraes | ключ на ресурс, например на клиента [1] |
| | Axon | субъект плюс `group`; id из поля `@DataSubjectId` (`prefix` + `toString()`) или из вызова [4][5] |
| | Akka | субъект; обёртка `WithDataSubjectId`, id открыт в конверте; id можно строить от `persistenceId` [24][26] |
| | Kurrent (блог) | субъект; поле `[DataSubjectId]` и копия id в метаданных [15] |
| | cloak | ключ на vault или `label` поля, не на субъекта [36] |
| | Marten, Eventuous, Commanded | механизма нет [28][31][33] |
| Слой; что видит апкастер | Axon | обёртка конвертера; апкастер видит шифротекст (вывод) [5][11] |
| | Akka | сериализатор `WithDataSubjectId` шифрует нагрузку события целиком [24] |
| | Kurrent (блог) | JSON-сериализатор; поле становится строкой `crypto.<base64>` [15] |
| | cloak_ecto | `Ecto.Type` колонки: `dump` шифрует, `load` расшифровывает [37] |
| | Marten | шифрования нет; правило задним числом переписывает `data` в `mt_events` [29] |
| Читатель после уничтожения | Axon | `replacement` (`""`) для `String`, `null`, default примитива; свой провайдер [7] |
| | Akka | `payload = None`; свёртка и обработчики разбирают его сами [24] |
| | Kurrent (блог) | `"***"` для строки, `default(T)` для прочих (0, `DateTime.MinValue`) [15] |
| | Verraes, FP | пустое значение или «John Doe» с номером запроса [2] |
| | cloak | `{:error, MissingCipher}`; тип Ecto возвращает `:error` [36][37] |
| | Marten | значение из правила маскирования, заголовок — по желанию [28] |
| Хранилище ключей | Axon | JPA/JDBC-таблица, Vault (master key, HSM/KMS), keystore, PKCS#11, память [6] |
| | Akka | своя `KeyManagement` (например, Vault); keystore-файл — только один узел [24][25] |
| | Kurrent (блог) | словарь в памяти; на записи — «получить или создать» [15] |
| | cloak | ключи из конфигурации в ETS vault'а [36] |
| | DEK / KEK, кеш | в библиотеках нет; обёртку ключей даёт только Vault / HSM у Axon [6] |
| Снапшоты | Axon | тот же конвертер [9] |
| | Akka | тот же ключ; несколько субъектов — отдельные части `WithDataSubjectId` [23][24] |
| Read-модели | Akka | событие удаления, чистка read-side, ключ удаляется позже (через неделю) [23] |
| | Kurrent (форум) | событие удаления и truncate; проекции чистят свои данные [21] |
| | Marten | не меняются до пересборки [28] |
| | Verraes | `GDPRDeletionWasRequested`; потребители удаляют копии [2] |
| Брокер | Akka | зашифрованные события с общими ключами или retention [23] |
| Память процесса | Akka | периодическая пассивация [23] |
| Поиск, уникальность | Akka | `eventsByTag` по id субъекта [22] |
| | cloak_ecto | HMAC-колонка; равенство значений видно [37] |
| | остальные | не описано |
| Подтверждение, аудит | Akka | только завершение `shred` (`Done`) [25] |
| | Axon | `deleteKey`; отчёта нет [6] |
| | Marten | заголовок `masked` на событии [28] |
| | KurrentDB | флаг `IsRedacted`; UI помечает событие [18] |
| | Verraes, FP | номер запроса в заглушке [2] |

## Развилки

1. **Единица ключа: субъект или поток.**
   - Ключ на субъекта выбирают все, кто механизм реализует (Axon, Akka, пример Kurrent), и Verraes
     [1][4][15][24]. Один ключ закрывает все ПДн человека, где бы они ни лежали: в потоке другого агрегата, в
     снапшоте, в копии. Цена — событию с ПДн нескольких людей нужно несколько ключей. У Axon для этого есть `group` с
     отдельным `@DataSubjectId`, у Akka — свой сериализатор по частям [4][24].
   - Ключ от потока у Akka — допустимый частный случай: id субъекта строится от `persistenceId` [26]. Но так не
     достать ПДн человека в чужих потоках — это показывает пример Akka с комментариями к посту [23].
   - Несколько ключей на субъекта (`group` / `prefix`) позволяют стирать поля выборочно [4].
2. **Где хранится id субъекта.**
   - Варианты: поле нагрузки с аннотацией (Axon, Kurrent), конверт (Akka), копия в метаданных (Kurrent).
   - При хранении в поле id должен быть открытым и сам не быть ПДн; Akka советует UUID или хеш с солью [26].
   - Метаданные нужны, когда десериализатор не знает схемы события [15].
   - Вывод: кодек `:core` не видит ни `%Context{}`, ни метаданных (`map.md`, Notes). Значит, id субъекта он может
     взять только из самой структуры события — как у Axon и в предложении для Eventuous [31][32].
3. **Гранулярность шифротекста: поле или событие.**
   - Поле (Axon, Kurrent): после стирания остальное событие читается и свёртка продолжается. Но тип поля должен
     вместить шифротекст — либо `String` / `byte[]`, либо отдельное поле `…Encrypted` [4].
   - Событие целиком (Akka): формат не зависит от схемы, но после shred пропадают и данные, не относящиеся к ПДн, а
     обработчик получает `None` [24].
4. **Слой и апкаст.**
   - Обёртка сериализатора (Axon, Akka, Kurrent) делает шифрование прозрачным для домена. Цена — апкастер,
     работающий над сериализованной формой, видит шифротекст (вывод для Axon) [5][11].
   - Переписывание истории (Marten, redaction в KurrentDB, hard delete в EventStore) обходится без ключей. Цена —
     нарушенная неизменяемость, нетронутые проекции и бэкапы и тихие сбои (#5199, #5234) [18][28][30][34].
   - Вывод: в `:core` апкаст тоже идёт над wire-конвертом до `load` (`map.md`, Notes) — позиция та же, что у Axon.
5. **Забытое значение: замена, явное отсутствие или ошибка.**
   - Прозрачная замена (Axon, Kurrent): свёртка и проекции работают без правок, но стёртое значение неотличимо от
     настоящего, а `0`, `DateTime.MinValue` или `null` могут нарушить инвариант. Axon смягчает это атрибутом
     `replacement` и сохранённой открытой частью [7][15].
   - Явное отсутствие (`None` у Akka): обработать его обязан каждый потребитель [24].
   - Ошибка (cloak). Так `:core` сегодня ведёт себя с нечитаемым событием: свёртка падает, проекция бесконечно
     повторяет попытку (`map.md`, Notes). Ни одно из рассмотренных ES-решений при отсутствии ключа ошибку читателю
     не отдаёт.
6. **Хранилище ключей.**
   - Таблица в той же БД (JPA/JDBC у Axon): транзакционное «получить или создать» без гонки, но ключи попадают в те
     же бэкапы, что и данные. Akka поэтому требует retention для бэкапов ключей [6][23].
   - Vault / HSM: KEK держит само хранилище (master key Vault), политика — без `update`. Цена — токен и сетевой
     запрос на каждый промах [6].
   - Ни одна библиотека сама не оборачивает DEK ключом KEK — это вопрос тикета 03. Кеш ключей не документирован
     ни у кого.
7. **Порядок уничтожения.**
   - Сразу удалить ключ — пример Axon [6].
   - Сначала событие удаления, по которому read-side и другие сервисы чистят копии, а ключ удалить позже, с
     задержкой — Akka, сотрудник Kurrent, Verraes для FP [2][21][23]. Так решаются события в полёте и read-модели с
     открытыми ПДн, но стирание откладывается. При немедленном удалении копии у потребителей остаются на их
     совести.
   - Брокер: зашифрованные сообщения требуют общих ключей у потребителей, а retention удаляет данные только по
     истечении срока [23].
8. **Состояние в памяти.**
   - Akka допускает периодическую пассивацию вместо немедленного выгона процесса [23]; Axon об этом ничего не
     говорит.
   - Вывод: процесс агрегата в `:core` держит состояние до `idle_timeout` (60 с), и API для выгона нет (`map.md`,
     Notes). Это близко к подходу Akka, если 152-ФЗ допускает такую задержку (тикет 01).

## Не найдено

- **Axon.** Исходники модуля закрыты, поэтому не проверены формат шифротекста, режим AES в 5.x, кеш ключей и то, как
  хранится ключ в `secret_key` (открыто или обёрнутым). Поведение апкастеров с зашифрованными полями документация
  модуля не описывает — здесь есть только вывод [11]. Что происходит с копиями ключа в бэкапах БД после `deleteKey`,
  тоже не сказано.
- **Kurrent.** Официального руководства по crypto-shredding нет — только сторонняя статья 2021 года, снятая с
  живого сайта, и пример 2024 года [15][16]. Статья, которую на форуме обещал сотрудник, не найдена [21].
- **Marten.** Серия блог-постов участника команды о crypto shredding, на которую ссылается мейнтейнер [30], не
  найдена.
- **Akka.** Неясна судьба модуля после линейки 1.1: в Akka Enhancements 2.0.0 его нет [27], а объявления о
  прекращении не нашлось. Как адаптеры событий Akka (апкаст) видят `WithDataSubjectId`, не описано.
- **Eventuous, Commanded.** Реализаций нет — только issue #221 и recipe #4 [32][33]; пакетов на hex.pm тоже нет [39].
- **Ни у одного решения:**
  - подтверждения уничтожения в виде акта или события библиотеки;
  - blind index и проверки уникальности по ПДн в event sourcing — есть только HMAC-колонка cloak_ecto для Ecto [37];
  - двухуровневых ключей DEK / KEK внутри библиотеки;
  - данных о цене расшифровки при свёртке и о кеше ключей;
  - оценки по 152-ФЗ: источники обсуждают только GDPR, и мнения там расходятся [1][13].

## Источники

1. Mathias Verraes, «Eventsourcing Patterns: Crypto-Shredding», 2019-05-13, с дополнением о GDPR —
   https://verraes.net/2019/05/eventsourcing-patterns-throw-away-the-key/
2. Mathias Verraes, «Eventsourcing Patterns: Forgettable Payloads», 2019-05-13 —
   https://verraes.net/2019/05/eventsourcing-patterns-forgettable-payloads/
3. Axon Framework Reference 5.4, Data Protection: обзор —
   https://docs.axoniq.io/axon-framework-reference/5.4/data-protection/
4. там же, Annotations — https://docs.axoniq.io/axon-framework-reference/5.4/data-protection/annotations/
5. там же, Configuration — https://docs.axoniq.io/axon-framework-reference/5.4/data-protection/configuration/
6. там же, Crypto Engines — https://docs.axoniq.io/axon-framework-reference/5.4/data-protection/crypto-engines/
7. там же, Advanced Topics — https://docs.axoniq.io/axon-framework-reference/5.4/data-protection/advanced/
8. там же, Installation (лицензия) и Major Releases —
   https://docs.axoniq.io/axon-framework-reference/5.4/data-protection/installation/ ;
   https://docs.axoniq.io/axon-framework-reference/5.4/data-protection-release-notes/major-releases/
9. там же, Multi-Tenancy with Data Protection —
   https://docs.axoniq.io/axon-framework-reference/5.4/multi-tenancy/tenant-data-protection/
10. там же, Data Protection Module Migration (4.x → 5.x) —
    https://docs.axoniq.io/axon-framework-reference/5.4/data-protection-migration/migration-path/
11. Axon Framework Reference 4.11, Event Versioning (upcasters) —
    https://docs.axoniq.io/axon-framework-reference/4.11/events/event-versioning/
12. AxonIQ, «Protect sensitive data in an event-sourced application», 2021-02-24 —
    https://www.axoniq.io/blog/protect-sensitive-data-in-an-event-sourced-application
13. AxonIQ Discuss, «Crypto-Shredding and GDPR with Axon Framework», ответы сотрудников 2025-03-04 и 2025-05-19 —
    https://discuss.axoniq.io/t/crypto-shredding-and-gdpr-with-axon-framework/5987
14. GitHub API: `repos/AxonIQ/extension-data-protection` отвечает 404; поиск `org:AxonIQ` по data-protection и gdpr
    находит только `axon-dataprotection-config-api` и `axon-dataprotection-maven-plugin` — https://github.com/AxonIQ
15. Kurrent blog, Diego Martin, «Protecting Sensitive Data in Event-Sourced Systems with Crypto Shredding»,
    2021-08-12; исходный URL ниже на 2026-10-18 перенаправляет на главную блога, текст читался по снимку Wayback
    Machine `20260414214606` этого URL —
    https://www.kurrent.io/blog/protecting-sensitive-data-in-event-sourced-systems-with-crypto-shredding-1
16. kurrent-io/samples `fb9bbf5`, `Crypto_Shredding/Dotnet` (последняя правка каталога — `0083437`, 2024-03-06):
    `Serialization/EncryptorDecryptor.cs`, `Repository/CryptoRepository.cs`, `Serialization/JsonSerializer.cs` —
    https://github.com/kurrent-io/samples/tree/fb9bbf5/Crypto_Shredding/Dotnet
17. .NET API, `SymmetricAlgorithm.Mode` («The default is CBC») —
    https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.symmetricalgorithm.mode
18. KurrentDB docs v26.0, Redaction — https://docs.kurrent.io/server/v26.0/operations/redaction.html
19. kurrent-io/KurrentDB `929bdd7`, `docs/server/operations/scavenge.md` —
    https://github.com/kurrent-io/KurrentDB/blob/929bdd7/docs/server/operations/scavenge.md
20. kurrent-io/skills, `plugins/kurrent/skills/kurrent-docs/SKILL.md` —
    https://github.com/kurrent-io/skills/blob/main/plugins/kurrent/skills/kurrent-docs/SKILL.md
21. Kurrent Discuss, «Handling GDPR data requests», ответ сотрудника Event Store от 2020-12-10 —
    https://discuss.kurrent.io/t/handling-gdpr-data-requests/2941
22. Akka Enhancements 1.1, GDPR for Akka Persistence —
    https://doc.akka.io/libraries/akka-enhancements/1.1/gdpr/index.html
23. там же, Shred or delete? — https://doc.akka.io/libraries/akka-enhancements/1.1/gdpr/shredding.html
24. там же, Using akka-gdpr — https://doc.akka.io/libraries/akka-enhancements/1.1/gdpr/using.html
25. там же, Encrypting data — https://doc.akka.io/libraries/akka-enhancements/1.1/gdpr/encryption.html
26. там же, Subject identifiers — https://doc.akka.io/libraries/akka-enhancements/1.1/gdpr/data-subject-id.html
27. Akka Enhancements 2.0.0, оглавление — https://doc.akka.io/libraries/akka-enhancements/current/
28. JasperFx/marten `2ece3a9`, `docs/events/protection.md` —
    https://github.com/JasperFx/marten/blob/2ece3a9/docs/events/protection.md
29. там же, `src/Marten/Events/EventGraph.Masking.cs`, `src/Marten/Events/Protected/EventDataMasking.cs`,
    `OverwriteEventOperation.cs`, `src/Marten/AdvancedOperations.cs` —
    https://github.com/JasperFx/marten/blob/2ece3a9/src/Marten/Events/EventGraph.Masking.cs
30. JasperFx/marten issues #2779, #3494, #5199 — https://github.com/JasperFx/marten/issues/2779 ;
    https://github.com/JasperFx/marten/issues/3494 ; https://github.com/JasperFx/marten/issues/5199
31. Eventuous/eventuous `60a7643`, `src/Core/src/Eventuous.Serialization/IEventSerializer.cs`,
    `src/Core/src/Eventuous.Persistence/AmendEvent.cs` —
    https://github.com/Eventuous/eventuous/blob/60a7643/src/Core/src/Eventuous.Serialization/IEventSerializer.cs
32. Eventuous/eventuous issue #221 «Crypto Shredding Serialization/Deserialization Support»;
    Eventuous/eventuous-docs `4989283` — https://github.com/Eventuous/eventuous/issues/221 ;
    https://github.com/Eventuous/eventuous-docs
33. commanded/recipes issue #4 «[Recipe] GDPR compliance» — https://github.com/commanded/recipes/issues/4
34. commanded/eventstore issue #269; `guides/Usage.md` на `49ba9f9`, раздел «Deleting streams» —
    https://github.com/commanded/eventstore/issues/269 ;
    https://github.com/commanded/eventstore/blob/49ba9f9/guides/Usage.md
35. commanded/commanded `v1.4.11`, `guides/Commands.md` —
    https://github.com/commanded/commanded/blob/v1.4.11/guides/Commands.md
36. danielberkompas/cloak `9a3d10c`: `lib/cloak/vault.ex`, `lib/cloak/ciphers/aes_gcm.ex`, `lib/cloak/crypto.ex` —
    https://github.com/danielberkompas/cloak/blob/9a3d10c/lib/cloak/ciphers/aes_gcm.ex ; https://hexdocs.pm/cloak/
37. danielberkompas/cloak_ecto `9989e73`: `lib/cloak_ecto/type.ex`, `lib/cloak_ecto/types/hmac.ex`,
    `guides/how_to/rotate_keys.md`, `guides/how_to/closure_wrapping.md` —
    https://github.com/danielberkompas/cloak_ecto/blob/9989e73/lib/cloak_ecto/types/hmac.ex ;
    https://hexdocs.pm/cloak_ecto/
38. Erlang/OTP `crypto:crypto_one_time_aead/7` (при неудачной проверке тега возвращает `error`); проверено вызовом в
    OTP 29 с чужим ключом — https://www.erlang.org/doc/apps/crypto/crypto.html#crypto_one_time_aead/7
39. hex.pm API, поиск `shred`, `shredding`, `gdpr`, `pii` — https://hex.pm/api/packages?search=shredding
