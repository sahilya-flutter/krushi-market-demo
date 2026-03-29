import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:krushi_market_mobile/features/krushivishayk/data/app_constants.dart';
import 'package:krushi_market_mobile/features/krushivishayk/data/krushimahiti_model.dart';
import 'package:krushi_market_mobile/features/krushivishayk/data/services/krushi_mahiti_service.dart';
import 'package:krushi_market_mobile/features/krushivishayk/presentation/screens/krushivishayk_details.dart';
import 'package:krushi_market_mobile/features/krushivishayk/presentation/widgets/app_bar_widget.dart';
import 'package:krushi_market_mobile/features/krushivishayk/presentation/widgets/category_filter_widget.dart';
import 'package:krushi_market_mobile/features/krushivishayk/presentation/widgets/content_list_widget.dart';
import 'package:krushi_market_mobile/features/krushivishayk/presentation/widgets/empty_state.dart';
import 'package:krushi_market_mobile/features/krushivishayk/presentation/widgets/error_state.dart';
import 'package:krushi_market_mobile/features/krushivishayk/presentation/widgets/featured_section_widget.dart';
import 'package:krushi_market_mobile/features/krushivishayk/presentation/widgets/scroll_to_top_button.dart';
import 'package:krushi_market_mobile/features/krushivishayk/presentation/widgets/search_bar_widget.dart';
import 'package:krushi_market_mobile/features/krushivishayk/presentation/widgets/section_header_widget.dart';

class KrushiVishayakScreen extends StatefulWidget {
  const KrushiVishayakScreen({super.key});

  @override
  State<KrushiVishayakScreen> createState() => _KrushiVishayakScreenState();
}

class _KrushiVishayakScreenState extends State<KrushiVishayakScreen> {
  late final KrushiMahitiService _service;
  late final ScrollController _scrollController;
  late final TextEditingController _searchController;

  final List<KrushiMahiti> _mahitiList = [];
  List<KrushiMahiti> _featuredMahiti = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasError = false;
  String _errorMessage = '';
  int _currentPage = 1;
  int _totalPages = 1;
  String? _selectedCategory;
  bool _showScrollToTop = false;

  static const List<Map<String, String>> _categories = [
    {'name': 'सर्व', 'slug': ''},
    {'name': '🌦️ हवामान', 'slug': 'weather'},
    {'name': '🌾 शेती', 'slug': 'farming'},
    {'name': '💰 बाजार', 'slug': 'market'},
    {'name': '📋 योजना', 'slug': 'schemes'},
  ];

  @override
  void initState() {
    super.initState();
    _service = KrushiMahitiService();
    _scrollController = ScrollController()..addListener(_onScroll);
    _searchController = TextEditingController();
    _loadMahiti();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _service.dispose();
    super.dispose();
  }

  // ==================== SCROLL HANDLER ====================
  void _onScroll() {
    final showButton =
        _scrollController.offset > AppConstants.scrollToTopThreshold;
    if (showButton != _showScrollToTop) {
      setState(() => _showScrollToTop = showButton);
    }

    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent -
                AppConstants.loadMoreThreshold &&
        !_isLoadingMore &&
        _currentPage < _totalPages) {
      _loadMoreMahiti();
    }
  }

  // ==================== API CALLS ====================
  Future<void> _loadMahiti({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _currentPage = 1;
        _mahitiList.clear();
        _featuredMahiti.clear();
      });
    }

    setState(() {
      _isLoading = true;
      _hasError = false;
      _errorMessage = '';
    });

    try {
      final response = await _service.fetchMahiti(
        page: _currentPage,
        category: _selectedCategory,
        search: _searchController.text.trim().isEmpty
            ? null
            : _searchController.text.trim(),
      );

      if (mounted) {
        setState(() {
          _mahitiList.addAll(response.items);
          _featuredMahiti = _mahitiList.where((m) => m.isFeatured).toList();
          _totalPages = response.totalPages;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _loadMoreMahiti() async {
    setState(() {
      _isLoadingMore = true;
      _currentPage++;
    });

    try {
      final response = await _service.fetchMahiti(
        page: _currentPage,
        category: _selectedCategory,
      );

      if (mounted) {
        setState(() {
          _mahitiList.addAll(response.items);
          _isLoadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          _currentPage--;
        });
        _showErrorSnackbar('अधिक माहिती लोड करताना त्रुटी आली');
      }
    }
  }

  // ==================== ACTIONS ====================
  void _onCategorySelected(String? slug) {
    setState(() {
      _selectedCategory = slug?.isEmpty == true ? null : slug;
      _currentPage = 1;
      _mahitiList.clear();
      _featuredMahiti.clear();
    });
    _loadMahiti();
  }

  void _navigateToDetail(KrushiMahiti mahiti) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MahitiDetailScreen(mahiti: mahiti),
      ),
    );
  }

  void _scrollToTop() {
    _scrollController.animateTo(
      0,
      duration: AppConstants.animationDuration,
      curve: Curves.easeOut,
    );
  }

  void _showErrorSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ==================== BUILD ====================
  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        context.go('/');
        return false;
      },
      child: Scaffold(
        backgroundColor: AppConstants.backgroundColor,
        body: RefreshIndicator(
          onRefresh: () => _loadMahiti(refresh: true),
          color: Colors.green.shade700,
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              const AppBarWidget(),
              SearchBarWidget(
                controller: _searchController,
                onSearch: () => _onCategorySelected(_selectedCategory),
              ),
              CategoryFilterWidget(
                categories: _categories,
                selectedCategory: _selectedCategory,
                onCategorySelected: _onCategorySelected,
              ),
              if (_featuredMahiti.isNotEmpty && !_isLoading)
                FeaturedSectionWidget(
                  featuredMahiti: _featuredMahiti,
                  onTap: _navigateToDetail,
                ),
              if (!_isLoading && !_hasError) const SectionHeaderWidget(),
              if (_hasError && _mahitiList.isEmpty)
                ErrorStateWidget(
                  errorMessage: _errorMessage,
                  onRetry: () => _loadMahiti(refresh: true),
                )
              else if (!_hasError && _mahitiList.isEmpty && !_isLoading)
                const EmptyStateWidget()
              else
                ContentListWidget(
                  mahitiList: _mahitiList,
                  isLoading: _isLoading,
                  isLoadingMore: _isLoadingMore,
                  hasError: _hasError,
                  onTap: _navigateToDetail,
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ],
          ),
        ),
        floatingActionButton: _showScrollToTop
            ? ScrollToTopButton(onPressed: _scrollToTop)
            : null,
      ),
    );
  }
}
