# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Publishing API is a Ruby on Rails JSON API (api_only mode) that serves as the central content workflow platform for GOV.UK. It is the authoritative store for all government content and manages the publishing lifecycle (draft → published → unpublished). It sends content downstream to draft and live Content Stores via HTTP, and broadcasts events over RabbitMQ.

## Common Commands

### Running Tests

```bash
bundle exec rake                # default: rubocop + rspec + pact:verify
bundle exec rake spec           # RSpec only
bundle exec rspec spec/path/to/spec.rb        # single file
bundle exec rspec spec/path/to/spec.rb:42     # single example by line number
```

### Linting

```bash
bundle exec rake rubocop        # Ruby linting (rubocop-govuk)
sqlfluff lint                   # SQL linting
sqlfluff fix                    # SQL auto-fix
```

### Other

```bash
bundle exec rails db:setup      # database setup
bundle exec rake build_schemas  # rebuild JSON content schemas
bundle exec rspec --options .rspec.benchmark  # benchmarks (requires real DB dump)
```

### Running the App

Web server runs on port 3093 (`bundle exec unicorn -c ./config/unicorn.rb -p 3093`). Background jobs run via Sidekiq (`bundle exec sidekiq -C ./config/sidekiq.yml`). Recommended to use GOV.UK Docker for local development.

## Architecture

### Command Pattern (Core Business Logic)

All write operations go through command objects in `app/commands/v2/`. Each command inherits from `Commands::BaseCommand` and implements `call`. The `BaseCommand.call` class method wraps execution in `EventLogger.log_command` (persisting requests to the `events` table) and fires `after_transaction_commit` callbacks. Controllers are thin and delegate to Commands (writes) or Query objects (reads).

Key commands: `PutContent`, `Publish`, `Republish`, `Unpublish`, `DiscardDraft`, `PatchLinkSet`.

### Query Objects

Read-only operations live in `app/queries/` (e.g., `GetContent`, `GetContentCollection`, `GetExpandedLinks`). Controllers call these directly for GET endpoints.

### Downstream Pipeline

1. A command triggers a Sidekiq job (`DownstreamDraftJob` or `DownstreamLiveJob`)
2. The job calls `DownstreamService` which writes to content stores via `ContentStoreWriter`
3. Live jobs also broadcast to RabbitMQ via `QueuePublisher`
4. Live jobs enqueue `DependencyResolutionJob` to find and update all content linking to the changed item

### Link Expansion

`LinkExpansion` (in `lib/link_expansion.rb`) walks a `LinkGraph` built from the `links` table, resolves related editions via `ContentCache`, and embeds them inline. `ExpansionRules` (in `lib/expansion_rules/`) controls which fields are included per link type.

### Service Registry

External services (draft/live content stores, queue publisher, statsd) are registered at boot in `config/initializers/services.rb` via `PublishingAPI.register_service(name:, client:)` and accessed via `PublishingAPI.service(:name)`.

### Data Model

- **Document**: A `content_id` + `locale` pair. Unique identifier for a piece of content.
- **Edition**: A version of a Document with states: draft, published, superseded, unpublished.
- **LinkSet / Link**: Relationships between content. Links can be link-set links or edition links.
- **Unpublishing**: Tracks previously published editions removed from the live site.
- **Event**: Audit log of all mutating API requests.
- **Action**: Activity record on an edition for publishing app workflows.
- **PathReservation**: Reserves a URL path on GOV.UK for a piece of content.

### Database

PostgreSQL with heavy use of JSONB columns (`details`, `links`, `routes`, `redirects`) and GIN indexes. Uses `with_advisory_lock` gem for distributed locking and `strong_migrations` for safe migration patterns.

### Sidekiq Queues (priority order)

`downstream_high` → `dependency_resolution` → `downstream_low` → `experiments` → `default` → `import`

### Authentication

GDS SSO (`gds-sso` gem) with `before_action :authenticate_user!` on all controllers.

### GraphQL

A GraphQL API at `/graphql` using `graphql-ruby`, with types/resolvers/sources in `app/graphql/`.

### Content Schemas

JSON schemas for GOV.UK content formats live in `content_schemas/`. Rebuild with `bundle exec rake build_schemas`.

### Pact Contract Tests

Publishing API is a **provider** for `gds-api-adapters` and a **consumer** against `content-store`. Pact files are in `spec/pacts/`.

## Key Conventions

- Follows [GOV.UK Rails app conventions](https://docs.publishing.service.gov.uk/manual/conventions-for-rails-applications.html)
- Ruby linting via `rubocop-govuk` (inherits shared GOV.UK config)
- All external HTTP is blocked in tests via WebMock
- Tests use FactoryBot factories (in `spec/factories/`), DatabaseCleaner, and Sidekiq test mode
- 60+ locales supported; content is locale-specific at the Document level
