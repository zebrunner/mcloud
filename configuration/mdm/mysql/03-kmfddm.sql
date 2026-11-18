-- The MySQL schema of KMFDDM v0.8.3 (MIT, github.com/jessepeterson/kmfddm) for NanoHUB 0.2.0:
-- mcloud-mdm-mysql applies it at its first start (README.md#mdm)
CREATE TABLE declarations (
    identifier VARCHAR(255) NOT NULL,
    type       VARCHAR(255) NOT NULL,
    payload    JSON NOT NULL,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP NOT NULL,
    touched_ct INT DEFAULT 0 NOT NULL,

    -- previously: AS (SHA1(CONCAT(identifier, type, payload, created_at, touched_ct))) STORED
    -- due to a schema management system this type of column isn't used
    -- despite MySQL supporting it just fine. instead we manually inject the
    -- stored SHA-1 in the SQL in declarations.go.
    server_token CHAR(40) NOT NULL,

    PRIMARY KEY (identifier),

    CHECK (type != ''),
    INDEX (type)
);

CREATE TABLE set_declarations (
    set_name               VARCHAR(255) NOT NULL,
    declaration_identifier VARCHAR(255) NOT NULL,

    PRIMARY KEY (set_name, declaration_identifier),

    CHECK (set_name != ''),
    CHECK (declaration_identifier != ''),

    FOREIGN KEY (declaration_identifier)
        REFERENCES declarations (identifier),

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE enrollment_sets (
    enrollment_id VARCHAR(255) NOT NULL,
    set_name      VARCHAR(255) NOT NULL,

    PRIMARY KEY (enrollment_id, set_name),

    CHECK (enrollment_id != ''),
    CHECK (set_name != ''),

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE status_declarations (
    enrollment_id   VARCHAR(255) NOT NULL,

    -- we don't setup a FK here because the reported identifier may be deleted
    -- or otherwise not tracked in our DB.
    declaration_identifier VARCHAR(255) NOT NULL,

    active       BOOLEAN NOT NULL,
    valid        VARCHAR(255) NOT NULL,
    server_token VARCHAR(255) NOT NULL,
    -- technically this is a duplication of the data in the declarations but
    -- because we may get status on declarations we don't know about we should
    -- keep this for posterity. note this is the shorter type and not the full
    -- delcaration type.
    item_type    VARCHAR(255) NOT NULL,

    reasons JSON NULL,

    status_id VARCHAR(255) NULL,

    PRIMARY KEY (enrollment_id, declaration_identifier),

    CHECK (enrollment_id != ''),
    CHECK (declaration_identifier != ''),

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE status_values (
    enrollment_id   VARCHAR(128) NOT NULL,

    path VARCHAR(255) NOT NULL,
    container_type VARCHAR(6) NOT NULL, -- object|array
    value_type     VARCHAR(7) NOT NULL, -- string|number|boolean
    value VARCHAR(255) NOT NULL,

    status_id VARCHAR(255) NULL,

    INDEX (enrollment_id),
    INDEX (path),
    INDEX (enrollment_id, path),

    -- beware: we can get close to the maximum index size if our columns are too large
    UNIQUE (enrollment_id, path, container_type, value_type, value),

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE status_errors (
    enrollment_id   VARCHAR(255) NOT NULL,

    path VARCHAR(255) NOT NULL,
    error JSON NOT NULL,

    status_id VARCHAR(255) NULL,
    row_count INT DEFAULT 0 NOT NULL,

    INDEX (enrollment_id),

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP NOT NULL,

    INDEX (created_at),
    INDEX (enrollment_id, row_count)
);

CREATE TABLE status_reports (
    enrollment_id   VARCHAR(255) NOT NULL,

    status_report JSON,

    status_id VARCHAR(255) NULL,
    row_count INT DEFAULT 0 NOT NULL,

    INDEX (enrollment_id),

    CHECK (enrollment_id != ''),
    CHECK (status_report != '' AND status_report != 'null'),

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP NOT NULL,

    INDEX (created_at),
    INDEX (enrollment_id, row_count)
);
