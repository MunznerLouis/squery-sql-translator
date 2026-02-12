# SQuery-SQL-Translator

> Bidirectional translator between SQuery and SQL

- Convert SQuery URLs to SQL queries and SQL queries back to SQuery URLs.
Fully configurable to adapt to any database schema.
This project has been heavily thought to be compatible in the scope of the Netwrix Identity Manager software, and might not work as intended for a bigger scope that that.
- Compatible with Powershell 5.1 

- If this project doesn't satisfy your needs, you can find a similar project here : https://github.com/velmie/q2sql

## 🚀 Quick Start
```powershell
# Clone
git clone https://github.com/you/SQuery-SQL-Translator
cd SQuery-SQL-Translator

# Import
Import-Module ./Core/SQuery-SQL-Translator.psd1

# Convert SQuery to SQL
$sql = Convert-SQueryToSql -Url "http://...?squery=..."
Write-Host $sql

# Convert SQL to SQuery (coming soon)
$url = Convert-SqlToSQuery -Query $sql -RootEntity "User"
```

## 📖 Documentation

- [Quick Start Guide](Docs/QUICKSTART.md) - Get started in 5 minutes
- [Installation](Docs/INSTALLATION.md) - Detailed installation instructions
- [Configuration Guide](Docs/CONFIGURATION.md) - How to configure for your database
- [SQuery to SQL](Docs/SQUERY-TO-SQL.md) - Complete guide for SQuery → SQL
- [Architecture](Docs/ARCHITECTURE.md) - Technical architecture overview

## ⚙️ Configuration

The translator uses JSON configuration files to adapt to your database schema:
```
Configs/
├── database-mapping.json    # Your tables and entities
├── column-rules.json        # Column transformation rules
├── join-patterns.json       # JOIN patterns
└── operators.json           # Operators mapping
```

See [Configuration Guide](Docs/CONFIGURATION.md) for details.

## 🎯 Features

- ✅ **SQuery → SQL**: Convert SQuery URLs to SQL queries
- 🔜 **SQL → SQuery**: Convert SQL queries to SQuery URLs (coming soon)
- 🔧 **Configurable**: JSON-based configuration for any database
- 🧪 **Tested**: Comprehensive test suite
- 📚 **Documented**: Complete documentation and examples
- 🔄 **Bidirectional**: Round-trip conversion support

## 📦 What's Included

- **Core Engine**: Robust parsing and transformation engine
- **Default Config**: Ready-to-use configuration example
- **Templates**: Minimal and full configuration templates
- **Examples**: Real-world configuration examples
- **Documentation**: Complete guides and API reference
- **Tests**: Automated test suite

## 🤝 Usage for Teams

### For End Users

1. Clone this repository
2. Copy a template from `Configs/templates/`
3. Edit with your database schema
4. Use the translator with your config

### For Administrators

1. Fork this repository
2. Customize `Configs/default/` with your company's database
3. Distribute your fork to your team
4. Team members use it directly without configuration

See [Configuration Guide](Docs/CONFIGURATION.md) for team setup.

## 🔧 Examples

### Example 1: Basic Usage
```powershell
$url = "http://localhost:5000/api/User?squery=select+Id,Name+where+Active=1"
$sql = Convert-SQueryToSql -Url $url

# Output:
# SELECT r.Id, r.Name_L1
# FROM [dbo].[Users] r
# WHERE r.Active = 1
```

### Example 2: Custom Configuration
```powershell
$sql = Convert-SQueryToSql `
    -Url $url `
    -ConfigDir "./MyProject/configs"
```

### Example 3: Validation
```powershell
# Validate your configuration
./Scripts/Validate-Config.ps1 -ConfigDir "./MyProject/configs"
```

## 📝 License

[My License is coming]

## 🙏 Contributing

Contributions are welcome! Please read the contributing guidelines first.

## 📧 Support

- Issues: https://github.com/you/SQuery-SQL-Translator/issues
- Discussions: https://github.com/you/SQuery-SQL-Translator/discussions
