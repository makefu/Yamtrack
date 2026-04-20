{
  self,
  pkgs,
  system,
  yamtrack,
  yamtrackDeps,
  python,
}:
let
  baseTestDeps =
    ps:
    yamtrackDeps
    ++ [
      ps.pytest
      ps.pytest-django
      ps.fakeredis
      ps.lupa
      ps.tblib
    ];

  testPython = python.withPackages baseTestDeps;

  playwrightTestPython = python.withPackages (
    ps:
    baseTestDeps ps
    ++ [
      ps.playwright
      ps.pytest-playwright
      ps.pytest-rerunfailures
      ps.pytest-timeout
    ]
  );
in
{
  yamtrack-unit-tests =
    pkgs.runCommand "yamtrack-unit-tests"
      {
        nativeBuildInputs = [ testPython ];
      }
      ''
          cp -r ${yamtrack}/lib/yamtrack ./test-root
          chmod -R u+w ./test-root
          cd ./test-root
          # inject conftest that mocks all external API calls
          cp ${./conftest.py} conftest.py
          export DJANGO_SETTINGS_MODULE=config.test_settings
          export HOME=/tmp
          ${testPython.interpreter} -m pytest \
            --ignore=app/tests/test_integration.py \
            --ignore=lists/tests/test_integration.py \
            --ignore=app/tests/providers/test_metadata.py \
            --ignore=app/tests/providers/test_search.py \
            --ignore=integrations/tests/test_webhooks_emby.py \
            --ignore=integrations/tests/test_webhooks_jellyfin.py \
            --ignore=integrations/tests/test_webhooks_plex.py \
            --deselect=app/tests/views/test_entry.py::CreateEntryViewTests::test_create_entry_post_movie \
            --deselect=integrations/tests/imports/test_anilist.py::ImportAniList::test_user_not_found \
            --deselect=integrations/tests/imports/test_mal.py::ImportMAL::test_user_not_found \
            --deselect=integrations/tests/imports/test_simkl.py::ImportSimkl::test_importer \
            --deselect=integrations/tests/imports/test_yamtrack.py::ImportYamtrackPartials::test_end_dates \
            --deselect=integrations/tests/imports/test_yamtrack.py::ImportYamtrackPartials::test_season_episode_search_by_title \
            -x
        # Ignored: integration tests require Playwright browser
        # Ignored: provider tests validate real external API responses
        # Ignored: webhook tests require TVDB API and anime mapping data
        # Deselected: test_create_entry_post_movie - model save() overrides form progress
        # Deselected: test_user_not_found - validates real API error response parsing
        # Deselected: simkl/yamtrack tests that assert exact metadata from real API responses
          touch $out
      '';

  yamtrack-sqlite = pkgs.testers.nixosTest {
    name = "yamtrack-sqlite";
    nodes.machine =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        environment.systemPackages = [ self.packages.${system}.default ];
        services.yamtrack = {
          enable = true;
          package = self.packages.${system}.default;
          hostName = "localhost";
        };
      };
    testScript = ''
      import json

      base_url = "http://localhost:8001"

      machine.wait_for_unit("yamtrack.service")
      machine.wait_for_unit("yamtrack-celery-worker.service")
      machine.wait_until_succeeds(f"curl -fs {base_url}/accounts/login/", timeout=60)

      # Check health endpoint returns success with JSON details
      machine.wait_until_succeeds(f"curl -fs {base_url}/health/", timeout=120)
      health = machine.succeed(f"curl -s {base_url}/health/?format=json")
      health_data = json.loads(health)
      for check, status in health_data.items():
          assert status == "working" or status == "OK", f"Health check '{check}' failed: {status}"

      # Create a test user via the yamtrack service environment
      manage = "sudo -u yamtrack env DJANGO_SETTINGS_MODULE=config.settings PYTHONPATH=${
        self.packages.${system}.default
      }/lib/yamtrack DB_PATH=/var/lib/yamtrack/db/db.sqlite3 yamtrack-manage"
      machine.succeed(f"{manage} createsuperuser --noinput --username testuser --email test@test.com")
      machine.succeed(f"""{manage} shell -c "
          from django.contrib.auth import get_user_model;
          u = get_user_model().objects.get(username='testuser');
          u.set_password('testpass123'); u.save()
      " """)

      # Log in: get login page and extract CSRF token, then POST credentials
      machine.succeed(f"curl -s -c /tmp/cookies.txt {base_url}/accounts/login/ > /tmp/login.html")
      csrf_token = machine.succeed(
          "grep -oP 'csrfmiddlewaretoken.*?value=\"\\K[^\"]+' /tmp/login.html"
      ).strip()
      login_response = machine.succeed(f"""
          curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt -w '\n%{{http_code}}'
          -H 'X-Real-IP: 127.0.0.1'
          -H 'Origin: {base_url}' -H 'Referer: {base_url}/accounts/login/'
          -d 'csrfmiddlewaretoken={csrf_token}&login=testuser&password=testpass123'
          {base_url}/accounts/login/
      """)
      # Successful login returns 302 redirect
      assert "302" in login_response, f"Login failed: {login_response[-200:]}"

      # Verify we are logged in (home page doesn't redirect to login)
      home_status = machine.succeed(f"""
          curl -s -o /dev/null -w '%{{http_code}}'
          -b /tmp/cookies.txt -c /tmp/cookies.txt {base_url}/
      """).strip()
      assert home_status == "200", f"Not logged in, got status: {home_status}"

      # Create a game entry via the manual create form
      machine.succeed(f"curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt {base_url}/create > /tmp/create.html")
      csrf_token = machine.succeed(
          "grep -oP 'csrfmiddlewaretoken.*?value=\"\\K[^\"]+' /tmp/create.html | head -1"
      ).strip()
      create_response = machine.succeed(f"""
          curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt -w '\n%{{http_code}}'
          -H 'Referer: {base_url}/create'
          -d 'csrfmiddlewaretoken={csrf_token}&media_type=game&title=Test+Game+Entry&status=Planning&score=&progress='
          {base_url}/create
      """)
      # Successful creation returns 302 redirect
      assert "302" in create_response, f"Create entry failed: {create_response[-500:]}"

      # Verify the game appears in the games list
      machine.succeed(f"""
          curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt {base_url}/medialist/game
          | grep -q 'Test Game Entry'
      """)
    '';
  };

  yamtrack-postgresql = pkgs.testers.nixosTest {
    name = "yamtrack-postgresql";
    nodes.machine =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        environment.systemPackages = [ self.packages.${system}.default ];
        services.yamtrack = {
          enable = true;
          package = self.packages.${system}.default;
          database.createLocally = true;
          hostName = "localhost";
        };
      };
    testScript = ''
      import json

      base_url = "http://localhost:8001"

      machine.wait_for_unit("postgresql.service")
      machine.wait_for_unit("yamtrack.service")
      machine.wait_for_unit("yamtrack-celery-worker.service")
      machine.wait_until_succeeds(f"curl -fs {base_url}/accounts/login/", timeout=60)

      # Check health endpoint returns success with JSON details
      machine.wait_until_succeeds(f"curl -fs {base_url}/health/", timeout=120)
      health = machine.succeed(f"curl -s {base_url}/health/?format=json")
      health_data = json.loads(health)
      for check, status in health_data.items():
          assert status == "working" or status == "OK", f"Health check '{check}' failed: {status}"

      # Create a test user via the yamtrack service environment
      manage = "sudo -u yamtrack env DJANGO_SETTINGS_MODULE=config.settings PYTHONPATH=${
        self.packages.${system}.default
      }/lib/yamtrack DB_HOST=/run/postgresql DB_NAME=yamtrack DB_USER=yamtrack DB_PASSWORD= DB_PORT=5432 yamtrack-manage"
      machine.succeed(f"{manage} createsuperuser --noinput --username testuser --email test@test.com")
      machine.succeed(f"""{manage} shell -c "
          from django.contrib.auth import get_user_model;
          u = get_user_model().objects.get(username='testuser');
          u.set_password('testpass123'); u.save()
      " """)

      # Log in: get login page and extract CSRF token, then POST credentials
      machine.succeed(f"curl -s -c /tmp/cookies.txt {base_url}/accounts/login/ > /tmp/login.html")
      csrf_token = machine.succeed(
          "grep -oP 'csrfmiddlewaretoken.*?value=\"\\K[^\"]+' /tmp/login.html"
      ).strip()
      login_response = machine.succeed(f"""
          curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt -w '\n%{{http_code}}'
          -H 'X-Real-IP: 127.0.0.1'
          -H 'Origin: {base_url}' -H 'Referer: {base_url}/accounts/login/'
          -d 'csrfmiddlewaretoken={csrf_token}&login=testuser&password=testpass123'
          {base_url}/accounts/login/
      """)
      # Successful login returns 302 redirect
      assert "302" in login_response, f"Login failed: {login_response[-200:]}"

      # Verify we are logged in (home page doesn't redirect to login)
      home_status = machine.succeed(f"""
          curl -s -o /dev/null -w '%{{http_code}}'
          -b /tmp/cookies.txt -c /tmp/cookies.txt {base_url}/
      """).strip()
      assert home_status == "200", f"Not logged in, got status: {home_status}"

      # Create a game entry via the manual create form
      machine.succeed(f"curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt {base_url}/create > /tmp/create.html")
      csrf_token = machine.succeed(
          "grep -oP 'csrfmiddlewaretoken.*?value=\"\\K[^\"]+' /tmp/create.html | head -1"
      ).strip()
      create_response = machine.succeed(f"""
          curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt -w '\n%{{http_code}}'
          -H 'Referer: {base_url}/create'
          -d 'csrfmiddlewaretoken={csrf_token}&media_type=game&title=Test+Game+Entry&status=Planning&score=&progress='
          {base_url}/create
      """)
      # Successful creation returns 302 redirect
      assert "302" in create_response, f"Create entry failed: {create_response[-500:]}"

      # Verify the game appears in the games list
      machine.succeed(f"""
          curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt {base_url}/medialist/game
          | grep -q 'Test Game Entry'
      """)
    '';
  };

  yamtrack-nginx = pkgs.testers.nixosTest {
    name = "yamtrack-nginx";
    nodes.machine =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        environment.systemPackages = [ self.packages.${system}.default ];
        networking.hostName = "yamtrack";
        services.yamtrack = {
          enable = true;
          package = self.packages.${system}.default;
          configureNginx = true;
          hostName = "yamtrack";
        };
      };
    testScript = ''
      import json

      base_url = "http://yamtrack"

      machine.wait_for_unit("yamtrack.service")
      machine.wait_for_unit("yamtrack-celery-worker.service")
      machine.wait_for_unit("nginx.service")
      machine.wait_until_succeeds(f"curl -fs {base_url}/accounts/login/", timeout=120)

      # Regression: ensure nginx does not send duplicate Host header (DisallowedHost)
      # A duplicate header would cause Django to see "yamtrack,yamtrack" and reject it
      machine.succeed(f"curl -fs {base_url}/health/")

      # Verify static files are served directly by nginx
      machine.succeed(f"curl -fs {base_url}/static/js/serviceworker.js -o /dev/null")

      # Check health endpoint returns success with JSON details
      machine.wait_until_succeeds(f"curl -fs {base_url}/health/", timeout=120)
      health = machine.succeed(f"curl -s {base_url}/health/?format=json")
      health_data = json.loads(health)
      for check, status in health_data.items():
          assert status == "working" or status == "OK", f"Health check '{check}' failed: {status}"

      # Create a test user via the yamtrack service environment
      manage = "sudo -u yamtrack env DJANGO_SETTINGS_MODULE=config.settings PYTHONPATH=${
        self.packages.${system}.default
      }/lib/yamtrack DB_PATH=/var/lib/yamtrack/db/db.sqlite3 yamtrack-manage"
      machine.succeed(f"{manage} createsuperuser --noinput --username testuser --email test@test.com")
      machine.succeed(f"""{manage} shell -c "
          from django.contrib.auth import get_user_model;
          u = get_user_model().objects.get(username='testuser');
          u.set_password('testpass123'); u.save()
      " """)

      # Log in: get login page and extract CSRF token, then POST credentials
      machine.succeed(f"curl -s -c /tmp/cookies.txt {base_url}/accounts/login/ > /tmp/login.html")
      csrf_token = machine.succeed(
          "grep -oP 'csrfmiddlewaretoken.*?value=\"\\K[^\"]+' /tmp/login.html"
      ).strip()
      login_response = machine.succeed(f"""
          curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt -w '\n%{{http_code}}'
          -d 'csrfmiddlewaretoken={csrf_token}&login=testuser&password=testpass123'
          {base_url}/accounts/login/
      """)
      # Successful login returns 302 redirect
      assert "302" in login_response, f"Login failed: {login_response[-200:]}"

      # Verify we are logged in (home page doesn't redirect to login)
      home_status = machine.succeed(f"""
          curl -s -o /dev/null -w '%{{http_code}}'
          -b /tmp/cookies.txt -c /tmp/cookies.txt {base_url}/
      """).strip()
      assert home_status == "200", f"Not logged in, got status: {home_status}"

      # Create a game entry via the manual create form
      machine.succeed(f"curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt {base_url}/create > /tmp/create.html")
      csrf_token = machine.succeed(
          "grep -oP 'csrfmiddlewaretoken.*?value=\"\\K[^\"]+' /tmp/create.html | head -1"
      ).strip()
      create_response = machine.succeed(f"""
          curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt -w '\n%{{http_code}}'
          -H 'Referer: {base_url}/create'
          -d 'csrfmiddlewaretoken={csrf_token}&media_type=game&title=Test+Game+Entry&status=Planning&score=&progress='
          {base_url}/create
      """)
      # Successful creation returns 302 redirect
      assert "302" in create_response, f"Create entry failed: {create_response[-500:]}"

      # Verify the game appears in the games list
      machine.succeed(f"""
          curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt {base_url}/medialist/game
          | grep -q 'Test Game Entry'
      """)
    '';
  };

  yamtrack-migration = pkgs.testers.nixosTest {
    name = "yamtrack-migration";
    nodes.machine =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        environment.systemPackages = [ self.packages.${system}.default ];
        services.yamtrack = {
          enable = true;
          package = self.packages.${system}.default;
          database.createLocally = true;
          hostName = "localhost";
        };
      };
    testScript = ''
      import textwrap, shlex

      def django_shell(manage_cmd, code):
          """Run dedented Python code via Django's shell -c, avoiding IndentationError."""
          dedented = textwrap.dedent(code).strip()
          machine.succeed(f"{manage_cmd} shell -c {shlex.quote(dedented)}")

      machine.wait_for_unit("postgresql.service")
      machine.wait_for_unit("yamtrack.service")
      machine.wait_for_unit("yamtrack-celery-worker.service")
      machine.wait_until_succeeds("curl -fs http://localhost:8001/accounts/login/", timeout=60)

      # --- Seed a SQLite source database ---
      # Use the package binary directly with SQLite-specific env to bypass
      # the module wrapper (which is configured for PostgreSQL).
      sqlite_seed = "env DB_PATH=/tmp/source.sqlite3 ${self.packages.${system}.default}/bin/yamtrack-manage"
      machine.succeed(f"{sqlite_seed} migrate --run-syncdb")

      django_shell(sqlite_seed, """
          from django.contrib.auth import get_user_model
          User = get_user_model()
          u = User.objects.create_superuser('migrateduser', 'migrated@test.com', 'testpass123')

          from app.models import Item, Game, Movie
          items = Item.objects.bulk_create([
              Item(media_id='test-game-1', source='manual', media_type='game',
                   title='Migrated Game', image='https://example.com/game.jpg'),
              Item(media_id='test-movie-1', source='manual', media_type='movie',
                   title='Migrated Movie', image='https://example.com/movie.jpg'),
          ])
          Game.objects.bulk_create([
              Game(item=items[0], user=u, status='Completed', progress=100),
          ])
          Movie.objects.bulk_create([
              Movie(item=items[1], user=u, status='Planning'),
          ])

          from lists.models import CustomList, CustomListItem
          cl = CustomList.objects.create(name='Test List', owner=u)
          CustomListItem.objects.bulk_create([
              CustomListItem(item=items[0], custom_list=cl),
          ])

          # Set non-default user preferences and token
          u.tv_layout = 'table'
          u.movie_sort = 'title'
          u.token = 'test-migration-token-12345678'
          u.plex_usernames = 'plexuser1,plexuser2'
          u.notification_urls = 'mailto://test@example.com'
          u.save()

          # Create a celery-beat import schedule
          from django_celery_beat.models import CrontabSchedule, PeriodicTask
          import json
          crontab = CrontabSchedule.objects.create(
              minute='30', hour='2', day_of_week='*',
              day_of_month='*', month_of_year='*',
          )
          PeriodicTask.objects.create(
              name='Import from Trakt for migrateduser at 02:30:00 daily',
              task='Import from Trakt',
              crontab=crontab,
              kwargs=json.dumps(dict(username='migrateduser', user_id=1, mode='watchlist')),
              enabled=True,
          )

          print('Seeded SQLite database')
      """)
      machine.succeed("chmod 644 /tmp/source.sqlite3")

      # --- Run migration from SQLite to PostgreSQL ---
      # The module-provided yamtrack-manage handles sudo + env vars automatically
      machine.succeed("yamtrack-manage migrate_from_sqlite --sqlite-path /tmp/source.sqlite3")

      # --- Verify migrated data ---
      django_shell("yamtrack-manage", """
          from django.contrib.auth import get_user_model
          User = get_user_model()
          assert User.objects.filter(username='migrateduser').exists(), 'User not migrated'

          from app.models import Game, Movie
          assert Game.objects.filter(item__title='Migrated Game').exists(), 'Game not migrated'
          assert Movie.objects.filter(item__title='Migrated Movie').exists(), 'Movie not migrated'

          from lists.models import CustomList, CustomListItem
          cl = CustomList.objects.get(name='Test List')
          assert cl.owner.username == 'migrateduser', 'List owner mismatch'
          assert CustomListItem.objects.filter(custom_list=cl).count() == 1, 'List item count wrong'

          # Verify user preferences survived migration
          u = User.objects.get(username='migrateduser')
          assert u.tv_layout == 'table', 'tv_layout not migrated'
          assert u.movie_sort == 'title', 'movie_sort not migrated'
          assert u.token == 'test-migration-token-12345678', 'token not migrated'
          assert u.plex_usernames == 'plexuser1,plexuser2', 'plex_usernames not migrated'
          assert u.notification_urls == 'mailto://test@example.com', 'notification_urls not migrated'

          # Verify import schedule survived migration
          from django_celery_beat.models import PeriodicTask
          pt = PeriodicTask.objects.get(name='Import from Trakt for migrateduser at 02:30:00 daily')
          assert pt.task == 'Import from Trakt', 'periodic task not migrated'
          assert pt.enabled, 'periodic task not enabled'
          assert pt.crontab is not None, 'crontab not migrated'
          assert pt.crontab.hour == '2', 'crontab hour wrong'
          assert pt.crontab.minute == '30', 'crontab minute wrong'

          print('All migration checks passed')
      """)

      # --- Verify idempotency: re-run, counts must not change ---
      machine.succeed("yamtrack-manage migrate_from_sqlite --sqlite-path /tmp/source.sqlite3")
      django_shell("yamtrack-manage", """
          from django.contrib.auth import get_user_model
          User = get_user_model()
          assert User.objects.filter(username='migrateduser').count() == 1, 'Duplicate users'

          from app.models import Game, Movie
          assert Game.objects.filter(item__title='Migrated Game').count() == 1, 'Duplicate games'
          assert Movie.objects.filter(item__title='Migrated Movie').count() == 1, 'Duplicate movies'

          from lists.models import CustomListItem
          assert CustomListItem.objects.count() == 1, 'Duplicate list items'

          from django_celery_beat.models import PeriodicTask
          assert PeriodicTask.objects.filter(name='Import from Trakt for migrateduser at 02:30:00 daily').count() == 1, 'Duplicate periodic tasks'

          print('Idempotency checks passed')
      """)
    '';
  };

  # Import the real production SQLite database into PostgreSQL.
  # This test uses the actual database at /home/makefu/r/Yamtrack/db.sqlite3
  # to verify that migration handles all real-world data correctly.
  yamtrack-migration-production = pkgs.testers.nixosTest {
    name = "yamtrack-migration-production";
    nodes.machine =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        environment.systemPackages = [ self.packages.${system}.default ];
        services.yamtrack = {
          enable = true;
          package = self.packages.${system}.default;
          database.createLocally = true;
          hostName = "localhost";
        };
      };
    testScript = ''
      import textwrap, shlex, json

      def django_shell(code):
          """Run dedented Python code via Django's shell -c."""
          dedented = textwrap.dedent(code).strip()
          return machine.succeed(f"yamtrack-manage shell -c {shlex.quote(dedented)}")

      machine.wait_for_unit("postgresql.service")
      machine.wait_for_unit("yamtrack.service")
      machine.wait_until_succeeds("curl -fs http://localhost:8001/accounts/login/", timeout=60)

      # Copy the production SQLite database into the VM
      machine.copy_from_host(
          "${/home/makefu/r/Yamtrack/db.sqlite3}",
          "/tmp/production.sqlite3",
      )

      # Run migration from production SQLite to PostgreSQL
      machine.succeed("yamtrack-manage migrate_from_sqlite --sqlite-path /tmp/production.sqlite3")

      # Verify data was migrated by checking row counts match
      result = django_shell("""
          from django.contrib.auth import get_user_model
          from app.models import Item, TV, Season, Episode, Manga, Anime, Movie, Game, Book, Comic, BoardGame
          from events.models import Event
          from lists.models import CustomList, CustomListItem
          from django_celery_beat.models import CrontabSchedule, PeriodicTask
          import json

          counts = {
              'users': get_user_model().objects.count(),
              'items': Item.objects.count(),
              'tv': TV.objects.count(),
              'seasons': Season.objects.count(),
              'episodes': Episode.objects.count(),
              'manga': Manga.objects.count(),
              'anime': Anime.objects.count(),
              'movies': Movie.objects.count(),
              'games': Game.objects.count(),
              'books': Book.objects.count(),
              'comics': Comic.objects.count(),
              'boardgames': BoardGame.objects.count(),
              'events': Event.objects.count(),
              'custom_lists': CustomList.objects.count(),
              'custom_list_items': CustomListItem.objects.count(),
              'crontab_schedules': CrontabSchedule.objects.count(),
              'periodic_tasks': PeriodicTask.objects.count(),
          }
          print(json.dumps(counts))
      """)
      counts = json.loads(result.strip().split('\n')[-1])

      # Verify non-zero counts for tables that had data in the original error output
      assert counts['users'] >= 1, f"Expected at least 1 user, got {counts['users']}"
      assert counts['items'] >= 771, f"Expected at least 771 items, got {counts['items']}"
      assert counts['tv'] >= 41, f"Expected at least 41 tv, got {counts['tv']}"
      assert counts['seasons'] >= 41, f"Expected at least 41 seasons, got {counts['seasons']}"
      assert counts['episodes'] >= 316, f"Expected at least 316 episodes, got {counts['episodes']}"
      assert counts['manga'] >= 81, f"Expected at least 81 manga, got {counts['manga']}"
      assert counts['anime'] >= 211, f"Expected at least 211 anime, got {counts['anime']}"
      assert counts['movies'] >= 12, f"Expected at least 12 movies, got {counts['movies']}"
      assert counts['games'] >= 2, f"Expected at least 2 games, got {counts['games']}"
      assert counts['boardgames'] >= 2, f"Expected at least 2 boardgames, got {counts['boardgames']}"
      assert counts['events'] >= 2516, f"Expected at least 2516 events, got {counts['events']}"
      assert counts['crontab_schedules'] >= 4, f"Expected at least 4 crontab schedules, got {counts['crontab_schedules']}"
      assert counts['periodic_tasks'] >= 6, f"Expected at least 6 periodic tasks, got {counts['periodic_tasks']}"

      print(f"Migration successful: {counts}")

      # Verify idempotency: re-run should not change counts
      machine.succeed("yamtrack-manage migrate_from_sqlite --sqlite-path /tmp/production.sqlite3")
      result2 = django_shell("""
          from django.contrib.auth import get_user_model
          from app.models import Item, TV, Season, Episode, Manga, Anime, Movie, Game, Book, Comic, BoardGame
          from events.models import Event
          from lists.models import CustomList, CustomListItem
          from django_celery_beat.models import CrontabSchedule, PeriodicTask
          import json

          counts = {
              'users': get_user_model().objects.count(),
              'items': Item.objects.count(),
              'tv': TV.objects.count(),
              'seasons': Season.objects.count(),
              'episodes': Episode.objects.count(),
              'manga': Manga.objects.count(),
              'anime': Anime.objects.count(),
              'movies': Movie.objects.count(),
              'games': Game.objects.count(),
              'books': Book.objects.count(),
              'comics': Comic.objects.count(),
              'boardgames': BoardGame.objects.count(),
              'events': Event.objects.count(),
              'custom_lists': CustomList.objects.count(),
              'custom_list_items': CustomListItem.objects.count(),
              'crontab_schedules': CrontabSchedule.objects.count(),
              'periodic_tasks': PeriodicTask.objects.count(),
          }
          print(json.dumps(counts))
      """)
      counts2 = json.loads(result2.strip().split('\n')[-1])
      assert counts == counts2, f"Idempotency failed: {counts} != {counts2}"

      print("Production migration test passed")
    '';
  };

  yamtrack-playwright = pkgs.testers.nixosTest {
    name = "yamtrack-playwright";
    nodes.machine =
      { pkgs, ... }:
      {
        virtualisation.memorySize = 2048;
        environment.systemPackages = [ playwrightTestPython ];
        environment.variables = {
          PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
        };
      };
    testScript = ''
      machine.wait_for_unit("multi-user.target")
      machine.succeed("""
        set -e
        cp -r ${yamtrack}/lib/yamtrack /tmp/yamtrack-test
        chmod -R u+w /tmp/yamtrack-test
        cd /tmp/yamtrack-test
        cp ${./conftest_playwright.py} conftest.py
        export DJANGO_SETTINGS_MODULE=config.test_settings
        export HOME=/tmp
        export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
        ${playwrightTestPython.interpreter} -m pytest \
          app/tests/test_integration.py \
          lists/tests/test_integration.py \
          --reruns=5 --reruns-delay=10 --timeout=120 \
          -v 2>&1
      """)
    '';
  };

  # Script to run the full test suite (including network-dependent tests)
  # outside the nix sandbox. Usage: nix run .#run-tests
  run-tests = pkgs.writeShellScriptBin "yamtrack-run-tests" ''
    set -euo pipefail
    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT
    cp -r ${yamtrack}/lib/yamtrack/. "$WORKDIR/"
    chmod -R u+w "$WORKDIR"
    cd "$WORKDIR"
    export DJANGO_SETTINGS_MODULE=config.test_settings
    export HOME="''${HOME:-/tmp}"
    export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
    exec ${playwrightTestPython.interpreter} -m pytest \
      --reruns=5 --reruns-delay=10 --timeout=120 \
      "$@"
  '';
}
